// ============================================================================
//  CHAPTER 2 — MAPS & NAVIGATION SERVICE (GOOGLE MAPS)
//  Source problem: "13: Google Maps"
//  (Systems Design Interview Questions With Ex-Google SWE, Jordan has no life)
// ============================================================================

#import "../template.typ": *

= Designing a Maps & Navigation Service

#block(fill: faint, radius: 6pt, inset: (x: 14pt, y: 11pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: slate, tracking: 0.1em)[PROBLEM SOURCE]
  #v(4pt)
  This chapter solves the problem posed in the talk
  #link("https://www.youtube.com/watch?v=1pmcoh4hc_A")[*"13: Google Maps"*]
  from the series _Systems Design Interview Questions With Ex-Google SWE_ (channel:
  _Jordan has no life_, 2024, 35 min). The talk designs a mapping and navigation
  product: how the map itself is served, how the road network becomes a graph, how
  routes and ETAs are computed, and how live traffic feeds back into both. We
  follow the same arc here, slowing every step down: full definitions before first
  use, capacity mathematics with every assumption stated, protocol specifications,
  and Rust reference implementations of the pieces an interviewer is most likely
  to ask you to sketch.
]

#v(0.4em)

== The Problem Statement

The interviewer finishes the small talk and says:

#block(inset: (left: 14pt), stroke: (left: 2pt + primary), above: 0.9em, below: 0.9em)[
  #text(style: "italic", size: 10.5pt)[
    "Design Google Maps. Users should be able to look at a map, search for
    places, and get directions from A to B — with an estimated time of arrival
    that accounts for current traffic."
  ]
]

Where Chapter 1's problem hid its difficulty behind a familiar CRUD interface,
this one hides its difficulty behind a familiar _picture_ — and that makes it
dangerous in a different way. A map *feels* like content: something you serve,
like an image on a website. Directions *feel* like a lookup: something you query,
like a row in a database. If you follow those feelings, you will design a file
server and a database, and both designs will be wrong. The map is a planet-sized
rendering and caching problem. Directions are a graph algorithm running at
planetary scale. And "current traffic" means the system's answers change *under
you, every few minutes*, driven by a firehose of GPS signals from millions of
moving phones. Three genuinely hard subsystems — geospatial serving, large-scale
graph search, and real-time stream processing — share one interview prompt, and
part of what the interviewer is measuring is whether you notice all three.

One term will appear in every section of this chapter, so let us define it
before anything else:

#defterm([ETA (estimated time of arrival)])[
  The system's prediction of how long a journey from A to B will take, usually
  expressed either as a duration ("47 minutes") or as an arrival clock time
  ("arrive 6:15 PM"). The word *prediction* is doing the work in that sentence:
  an ETA must be computed *before* the journey happens, from a model of the road
  network plus everything currently known about conditions on it — and it will be
  compared, by every user, against the reality that follows. ETA accuracy is the
  quality bar this whole chapter is judged against; Section 2.4 makes it a formal
  requirement and Section 2.18 shows how to measure it honestly.
]

== Scope & Clarifying Questions

Chapter 1 gave you the rule — never design the prompt you were handed; design
the prompt you *negotiated* — and this prompt needs it more than most, because
Google Maps is a dozen products wearing one icon. Map rendering, place search,
directions, turn-by-turn navigation, live traffic, Street View, satellite
imagery, transit schedules, offline maps, business listings, reviews… If you try
to design all of that, you will design none of it well. So the first job is to
shrink it, out loud, with the interviewer's help:

#tbl(
  (auto, 1fr),
  header: (hcell[Speaker], hcell[Dialogue]),
  body: (
    [*Candidate*], ["The full product is enormous — map rendering, place search, directions, turn-by-turn navigation, live traffic, Street View, satellite imagery, transit schedules, offline maps. Which parts are we designing?"],
    [*Interviewer*], ["Focus on five: render the map, search for places, compute directions with an ETA, show live traffic, and run a turn-by-turn navigation session. Skip Street View, satellite, transit, and offline."],
    [*Candidate*], ["What scale — how many users, and how many actively navigating at once?"],
    [*Interviewer*], ["One billion monthly users, a few hundred million daily. Assume up to 15 million people in an active navigation session at peak."],
    [*Candidate*], ["Latency expectations?"],
    [*Interviewer*], ["The map must feel instant while panning. A route request should come back within a second or two."],
    [*Candidate*], ["How accurate does the ETA need to be?"],
    [*Interviewer*], ["Within about ten percent of actual travel time on typical trips."],
    [*Candidate*], ["Do drivers' phones report GPS positions back to us during navigation? That would be our live traffic signal."],
    [*Interviewer*], ["Yes — anonymized location updates, with user consent, every few seconds while navigating."],
    [*Candidate*], ["Availability target? People use this while driving; a dead navigation app mid-highway is a safety problem."],
    [*Interviewer*], ["Four nines for the navigation path."],
  ),
)

Before we freeze the scope, look at what two of these questions quietly bought.
The *feature-list* question did not just trim scope — it established that the
interviewer will let you treat a giant product as a menu, which is the correct
posture for every "design X" prompt where X is a mature product. And the
question about *GPS reporting* is the single most valuable line in the exchange:
without phone-reported positions there is no live traffic, and without live
traffic the prompt collapses into "serve static files and run Dijkstra." One
question about *inputs* unlocked the most interesting subsystem of the entire
design. (The tip box below generalizes this.)

#block(fill: faint-blue, radius: 6pt, inset: (x: 14pt, y: 10pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: primary, tracking: 0.1em)[AGREED SCOPE]
  #v(4pt)
  Five features: *map rendering*, *place search*, *directions with ETA*,
  *live traffic*, *turn-by-turn navigation*. Scale: *1B MAU*, ~200M DAU,
  *15M concurrent navigation sessions* at peak. Latency: map feels instant,
  routes within ~1–2 s. ETA accurate to ~±10%. Navigation availability *99.99%*.
  Phones send anonymized GPS updates every few seconds while navigating.
]

#tip([Ask where the data comes from])[
  Most candidates ask about users and features; very few ask *"what data do we
  get to see?"* That single question unlocks this entire problem: the answer —
  GPS updates from phones, every few seconds, with consent — is what makes live
  traffic possible at all. In a real interview, the questions that reveal
  *inputs* are worth as much as the questions that reveal *scale*, and they are
  rarer, which makes them more memorable.
]

== Functional Requirements

Chapter 1 defined functional and non-functional requirements; recall that FRs
are what the system must *do* — observable behaviors, testable without knowing
the implementation. Here are ours, with a sentence each about where its
difficulty hides:

+ *FR-1 — Map rendering.* The user can view an interactive map of the world and
  pan and zoom it smoothly, from a whole-planet view down to individual streets.
  Sounds like serving images; is actually a planetary caching problem
  (Section 2.6).
+ *FR-2 — Place search.* The user can find places by name, address, or category
  ("coffee near me") and see them on the map. Sounds like text search; is
  actually text search *intersected with geography*, which is the interesting
  part (Section 2.9).
+ *FR-3 — Directions.* The user can request a route between two points and
  receives a good route: distance, step-by-step instructions, and a path drawn
  on the map. This is the graph algorithm (Section 2.8).
+ *FR-4 — ETA.* Every route comes with a travel-time estimate that reflects
  *current* conditions, not just speed limits. This requirement is what forces
  routing and traffic to be one mechanism rather than two (Section 2.7).
+ *FR-5 — Turn-by-turn navigation.* The user can start a navigation session and
  receives timely spoken and visual instructions, a live ETA that updates en
  route, and an automatic new route if they stray. This is the only stateful,
  session-oriented requirement — and therefore the one with the strict
  availability target (Section 2.13).
+ *FR-6 — Traffic overlay.* The map shows current congestion (green, yellow,
  red) on roads, fresh to within a few minutes. The visible tip of the streaming
  pipeline (Section 2.12).

Out of scope, stated explicitly so nobody can ambush us with them at minute
fifty: Street View and satellite imagery, public transit timetables, offline
maps, business-owner tooling, and social features.

== Non-Functional Requirements

This problem has one NFR that Chapter 1 never needed, and it is the one that
turns the design into a streaming system — so let us define it before the
target table.

#defterm([Freshness])[
  The age of the information behind an answer, measured from when reality
  changed to when the system's output reflects it. A traffic overlay that shows
  speeds from an hour ago is *stale*; our target is that any road's displayed
  condition reflects measurements from the last few minutes. Freshness is
  different from latency: latency asks "how fast do you answer?", freshness asks
  "how new is the answer's evidence?" A system can be fast and stale, or slow
  and fresh. It is the freshness requirement — not any throughput number — that
  makes this problem a *streaming* system rather than a static one.
]

The full set, stated as targets we can design and measure against:

#tbl(
  (auto, 1fr),
  header: (hcell[Quality], hcell[Target]),
  body: (
    [*Map latency*], [Tiles visible within ~100 ms while panning (p95); panning must never stutter],
    [*Route latency*], [Directions within ~1 s for typical trips; ~2 s for cross-country],
    [*ETA accuracy*], [Within ±10% of realized travel time on typical trips],
    [*Traffic freshness*], [Displayed speeds reflect the last ~2–5 minutes of reality],
    [*Availability*], [99.99% on the navigation path (4.4 s of allowed downtime per day); 99.9% elsewhere],
    [*Scale*], [1B MAU; ~200M DAU; 15M concurrent navigation sessions at peak],
  ),
)

#insight([Different subsystems, different NFRs])[
  Run your eye down that table and notice that "the system" has no single
  latency or availability number — and cannot have one, because its parts want
  opposite things. Tile serving is a massive, cacheable *read* workload where
  100 ms matters and a stale tile is harmless. Routing is a *compute* workload
  where one second is generous but the algorithm must be exact. The traffic
  pipeline is a *write* workload where a few minutes of lag degrade quality, not
  correctness. And navigation is a *session* workload where availability is a
  safety property. If an interviewer presses you for "the availability target,"
  the senior answer is: "it depends which plane you mean" — followed by the
  planes. Chapter 1 drew the same lesson with its control plane / data plane
  split; this chapter splits further.
]

== Back-of-the-Envelope Estimation

Chapter 1 taught the discipline — state assumptions, write them down, invite
correction — and it is identical here. What changes is *where* the numbers will
surprise you: in this problem the read path, the compute path, and the write
path each have their own scale story, and they point at three different
architectures.

*Assumptions:*

- 1B MAU, ~200M DAU. Each daily user views ~60 map tiles' worth of panning,
  searches ~2 places, and requests ~3 routes per day.
- 15M concurrent navigation sessions at peak; each phone uploads one GPS update
  every ~5 seconds while navigating; one update is ~150 bytes on the wire.
- The world's routable road network is on the order of *300 million directed
  edges* (two directions per piece of road, worldwide).
- A raster map tile averages ~20 KB; the world is mapped at zoom levels 0–20.

*Derived numbers:*

#tbl(
  (1.2fr, 0.85fr, 1.35fr),
  header: (hcell[Quantity], hcell[Estimate], hcell[How]),
  body: (
    [Map tile requests], [≈ 140k QPS avg, ~700k peak], [200M users × 60 tiles/day ÷ 86,400 s, ×5 peak factor],
    [Place search QPS], [≈ 5k avg, ~25k peak], [200M × 2/day ÷ 86,400, ×5],
    [Route request QPS], [≈ 7k avg, ~20k peak], [200M × 3/day ÷ 86,400, ×3],
    [GPS update ingress], [≈ 3M updates/s], [15M navigators ÷ 5 s per update],
    [Ingress bandwidth], [≈ 450 MB/s], [3M updates/s × 150 B],
    [Road graph size], [≈ 20 GB], [300M edges × ~64 B per adjacency record],
    [Naive tile storage], [≈ 29 PB], [$sum_(z=0)^(20) 4^z$ ≈ 1.47 trillion tiles × 20 KB],
  ),
)

#insight([What the math tells us])[
  Three conclusions drive everything that follows, and each one pre-answers a
  later section. First, tile traffic is enormous — 700k requests per second at
  peak — but *the content barely changes*, which makes it the textbook caching
  workload; Section 2.6 exists to make 95%+ of those requests vanish into a CDN
  before they ever touch us. Second, the road graph is only ~20 GB: it fits in
  the RAM of a handful of machines, so routing is an *in-memory* problem. But —
  and this is the arithmetic that justifies the chapter's most famous section —
  20k route QPS multiplied by ~3 CPU-seconds for a naive shortest-path search
  would demand *60,000 CPU cores*, which no fleet absorbs. Section 2.8's whole
  purpose is to shave those 3 seconds down to ~1 millisecond, at which point
  ~20 cores suffice. Third, 3M GPS updates per second is far too much for any
  request/response design; it demands a streaming pipeline, which Section 2.12
  builds. Read-heavy caching, in-memory compute, streaming writes: three
  subsystems, three shapes, one product.
]

== Core Challenge I: Serving the Map

Let us start with the thing the user actually sees. Someone opens the app and
looks at their city. They drag the map; new streets slide in. They pinch; the
view dives from the whole country to one neighborhood. Now think about what
each of those gestures *demands*: the right piece of the planet, rendered, on a
glass screen, in tens of milliseconds — for 200 million people a day. Rendering
the world on the fly for every gesture is out of the question; no fleet of
renderers survives 700k requests per second at 100 ms each. The entire solution
rests on one idea, and everything in this section is an unfolding of it:
*precompute the map as tiny, independently addressable squares, and cache those
squares everywhere.*

#defterm([Map tile])[
  A small, fixed-size square of the map — conventionally 256×256 pixels as an
  image, or the equivalent bundle of geometry as data — covering a specific
  rectangular patch of the Earth's surface. A screen full of map is assembled
  from a grid of tiles, like mosaic pieces laid edge to edge. Tiles are the
  unit of storage, of caching, and of transfer for every mainstream map
  service: the server thinks in tiles, the cache thinks in tiles, and the
  client assembles tiles.
]

#defterm([Zoom level])[
  The map's scale, expressed as an integer _z_ from 0 upward. At zoom 0 the
  *entire world* is one tile. Each step down splits every tile into four
  children, so zoom _z_ has $2^z$ tiles per axis and $4^z$ tiles in total.
  Zoom 5 is roughly a country; zoom 10 a city; zoom 15 a neighborhood; zoom 20
  shows a patch about 38 meters wide at the equator — individual buildings.
  The powers of four matter: they are why the total tile count explodes, and
  the explosion is what the storage section below must tame.
]

#defterm([Slippy-map tiling scheme])[
  The near-universal convention for *addressing* tiles: every tile is
  identified by three integers *(z, x, y)* — its zoom level and its grid
  coordinates, counted from the top-left of the world. To build the grid, the
  Earth's surface is first flattened with the Web Mercator projection (which
  maps the sphere to a square and caps latitude near ±85.05°, which is why
  polar regions never quite appear), then cut into the $2^z times 2^z$ grid.
  The payoff of this convention is determinism: given a latitude, a longitude,
  and a zoom, *anyone can compute which tile contains that point* with a
  closed-form formula — Section 2.14 implements it in eleven lines of Rust. So
  the client never asks the server "which tiles do I need?"; it already knows,
  and requests them by name.
]

The pyramid shape that falls out of the zoom rule is the whole storage story,
so let us look at it before taming it:

#v(0.3em)
#align(center)[
#canvas(h: 4.9cm)[
  // z0: single tile
  #node(0.6cm, 1.5cm, 1.6cm, 1.6cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #glabel(0.75cm, 0.9cm, [*z = 0*], fg: ink, size: 8pt)
  #glabel(0.6cm, 3.4cm, [1 tile], fg: slate)
  // z1: 2x2
  #node(3.6cm, 1.1cm, 1.2cm, 1.2cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(4.85cm, 1.1cm, 1.2cm, 1.2cm, [], fill: white, edge: primary, radius: 2pt)
  #node(3.6cm, 2.35cm, 1.2cm, 1.2cm, [], fill: white, edge: primary, radius: 2pt)
  #node(4.85cm, 2.35cm, 1.2cm, 1.2cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #glabel(3.9cm, 0.5cm, [*z = 1*], fg: ink, size: 8pt)
  #glabel(3.75cm, 3.8cm, [4 tiles], fg: slate)
  // z2: 4x4
  #node(7.5cm, 0.5cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(8.4cm, 0.5cm, 0.85cm, 0.85cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(9.3cm, 0.5cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(10.2cm, 0.5cm, 0.85cm, 0.85cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(7.5cm, 1.4cm, 0.85cm, 0.85cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(8.4cm, 1.4cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(9.3cm, 1.4cm, 0.85cm, 0.85cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(10.2cm, 1.4cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(7.5cm, 2.3cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(8.4cm, 2.3cm, 0.85cm, 0.85cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(9.3cm, 2.3cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(10.2cm, 2.3cm, 0.85cm, 0.85cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(7.5cm, 3.2cm, 0.85cm, 0.85cm, [], fill: faint-blue, edge: primary, radius: 2pt)
  #node(8.4cm, 2.3cm+0.9cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(9.3cm, 3.2cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #node(10.2cm, 3.2cm, 0.85cm, 0.85cm, [], fill: white, edge: primary, radius: 2pt)
  #glabel(8.1cm, 4.35cm, [16 tiles], fg: slate)
  #glabel(7.9cm, -0.15cm, [*z = 2*], fg: ink, size: 8pt)
  // z3 arrow + dots
  #glabel(11.6cm, 1.6cm, [#text(size: 15pt, fill: slate)[→]], size: 15pt)
  #glabel(12.4cm, 0.6cm, [*z = 20*], fg: ink, size: 8pt)
  #glabel(12.4cm, 1.1cm, [≈ 1.1 trillion], fg: slate)
  #glabel(12.4cm, 1.5cm, [tiles at that], fg: slate)
  #glabel(12.4cm, 1.9cm, [level alone], fg: slate)
  #glabel(12.4cm, 2.7cm, [one tile ≈ 38 m], fg: slate)
  #glabel(12.4cm, 3.1cm, [wide at equator], fg: slate)
]]
#v(0.2em)

Read the diagram left to right and watch the explosion happen. On the far left,
zoom 0: the entire planet in one square — one tile, mostly blue. At zoom 1, that
tile has split into its four children; the shaded squares track one patch of the
Earth as it subdivides. At zoom 2, sixteen tiles cover the world, and the same
patch is now a quarter of a quarter. The arrow then jumps the sequence forward
fifteen more levels to zoom 20, where the count is no longer drawable: about
1.1 trillion tiles at that level alone, each covering a patch 38 meters wide.
One tile became four became sixteen became a trillion; that geometric
progression, multiplied by ~20 KB a tile, is exactly where the ~29 PB estimate
in Section 2.5 came from.

So how do we afford a 29-petabyte map? We do not — two observations collapse it:

+ *Most tiles are uniform.* Roughly 70% of the planet is ocean; enormous areas
  beyond that are desert, ice, or forest. A solid-blue 256×256 square
  compresses to almost nothing — and, more powerfully, *it is the same square
  everywhere on Earth*. If we store tiles content-addressed (named by the hash
  of their contents; Section 2.10), every identical tile in the world is stored
  exactly *once*. The trillion collapse to the few percent of tiles that
  actually contain roads and labels, and 29 PB becomes merely large.
+ *Nobody looks at most of the world, most of the time.* Demand is violently
  skewed toward populated areas and common zooms: midtown Manhattan at zoom 16
  is served constantly; the mid-Pacific at zoom 20 essentially never. Skew like
  that is what caching feeds on — a cache holding the popular few percent
  serves the overwhelming majority of requests.

Which brings us to the machinery that exploits both observations:

#defterm([Content Delivery Network (CDN)])[
  A geographically distributed fleet of *edge caches*: servers in hundreds of
  cities, each holding copies of popular content physically close to users. A
  request is routed to the nearest edge location; on a *cache hit* the content
  is served locally — single-digit milliseconds, and zero load on our
  infrastructure; on a *miss* the edge fetches from our origin once and caches
  the copy for the next requester. A CDN turns a read-heavy, mostly-static
  workload into someone else's bandwidth, and the tile pyramid is the most
  read-heavy, most static workload imaginable.
]

#defterm([TTL (time to live) / cache hit ratio])[
  A cached entry's _TTL_ is how long an edge may serve it before revalidating
  with the origin — it is the dial between freshness and load, and you turn it
  per content type. The _hit ratio_ is the fraction of requests served from
  cache, and it is the number that decides whether the CDN strategy is working.
  For base map tiles we choose long TTLs (days; roads move slowly) and expect
  hit ratios above 95%. The *traffic overlay* tiles of Section 2.12 get TTLs of
  a minute or two, because stale traffic is worse than no traffic. Same cache,
  two TTLs — freshness is per-layer, not per-system.
]

#pitfall([Serving tiles from your own fleet])[
  The single most common junior mistake on this problem is to draw a "tile
  service" that renders or reads tiles on demand, per request. Run the numbers
  on that design: at 700k peak QPS with even a cheap 5 ms read, you need
  thousands of machines whose only job is to re-serve the same static squares
  forever — slow for distant users, vast, and pointless. The correct shape is:
  *pre-render tiles offline, push them to object storage, put a CDN in front,
  and let the origin see a single-digit percentage of traffic.* Rendering is a
  batch job that runs when the map changes, not a request path that runs when a
  user pans. Say that sentence in the interview and the map-serving discussion
  is over.
]

One design fork is worth naming now and deciding later (Section 2.17): tiles
can be *raster* (pre-rendered images) or *vector* (compact geometry the client
renders on its own GPU). We will serve vector tiles to modern clients — roughly
half the bytes, restyleable without re-rendering, and one tile set serves every
zoom-adjacent gesture smoothly — while keeping raster fallbacks for old
clients. Either way, everything you just learned — the pyramid, the addressing,
the CDN — is identical; only the payload changes.

Place search (FR-2) rides on the same geospatial ideas as tiles: a *spatial
index* lets us find "all places inside this patch of Earth" without scanning
200M records. We will define that structure once, in Section 2.7's storage
discussion and Section 2.14's code, because routing needs it too.

== Core Challenge II: Modeling the Road Network

Directions require a mathematical object we can search. Maps as humans know
them — pretty pictures of roads — are useless to an algorithm; what we need is
a structure that encodes *what connects to what, and at what cost*. That
structure is a graph, and building it from the road network is the second core
challenge.

#defterm([Graph / weighted directed graph])[
  A _graph_ is a set of *nodes* connected by *edges*. It is _directed_ when
  edges have a direction of travel — a one-way street is traversable only along
  its arrow — and _weighted_ when every edge carries a number measuring the
  *cost* of crossing it. We model intersections as nodes and stretches of road
  between them as edges, and we call one such directed road piece a *segment*.
  If this feels abstract, hold a city in your head: every intersection is a
  dot, every block between two intersections is an arrow or two, and the whole
  city's road network is exactly those dots and arrows.
]

#defterm([Segment])[
  The atomic unit of the road network: one directed piece of road between two
  nodes, carrying metadata — its geometry (the polyline of its shape), length,
  road class (residential, arterial, highway), speed limit, and any turn
  restrictions at its far end. Segments are also the unit of *traffic*: when we
  say "this road is slow," we mean "this segment's current crossing time is
  high," and every GPS update we receive is eventually attributed to exactly
  one segment (Section 2.12). One concept, two jobs: structure for the router,
  evidence for the traffic loop.
]

The crucial modeling choice is the edge *weight*, and it is worth thinking
through rather than accepting. Distance is the obvious candidate — it is
stable, measurable, and simple. But drivers do not minimize distance; they
minimize *time*, and the shortest route in miles is often the slowest route in
minutes. So an edge's weight is its *expected crossing time*: `length / current
expected speed`. Now watch what this one choice does for the whole chapter. On
an empty road, "current expected speed" is the speed limit. As Section 2.12's
pipeline observes real vehicles slowing down, it lowers that speed — and the
edge weight rises, automatically. Routing and traffic collapse into one
mechanism: *traffic is just edge weights that move.* FR-4, the traffic-aware
ETA, needed no new algorithm at all.

#defterm([Adjacency list])[
  The standard memory layout for sparse graphs: for every node, a list of its
  outgoing edges. Routing graphs are extremely sparse — an intersection has
  roughly 3–6 outgoing segments — so an adjacency list stores ~300M small
  records, the ~20 GB from Section 2.5, where a dense matrix representation
  would need space quadratic in the node count (petabytes of mostly zeros).
  Our routing engine holds adjacency lists *in RAM*: there is no database on
  the per-request path, which is how route latency survives its one-second
  budget.
]

One subtlety interviewers enjoy raising: a plain graph edge cannot express "you
may enter this intersection from Main Street but may *not* turn left onto 1st
Avenue." Turn restrictions break the fiction that cost lives on edges alone.
Two standard repairs: split nodes (one node per incoming direction, with edges
only for legal turns), or attach per-edge metadata that the search consults.
Either way, the core model — nodes, directed edges, time weights — survives
intact, and knowing the repair is enough at this level.

== Core Challenge III: Shortest Paths at Planetary Scale

With the road network modeled as a time-weighted graph, computing directions
becomes a precise mathematical problem:

#defterm([Shortest path problem])[
  Given a weighted graph and two nodes, find the path between them whose total
  edge weight is minimal. With our time-weighted segments, the shortest path is
  the *fastest route*, and its total weight *is* the route's ETA — the answer
  to FR-3 and FR-4 falls out of the same computation. That tidy reduction is
  why the modeling work in Section 2.7 mattered: one good model turns two
  product features into one well-studied algorithmic problem.
]

Now, which algorithm? The interviewer expects you to know the canonical answer
*and* to know why you cannot ship it. Let us build the ladder one rung at a
time — that ordering, from "correct but too slow" to "fast enough to serve,"
is itself the story of this section.

#defterm([Dijkstra's algorithm])[
  The classic exact solution, and still the right mental model. The idea:
  explore the graph outward from the source in order of increasing distance
  from it, like a stain spreading. Maintain for each node the best known
  distance (initially ∞ everywhere, 0 at the source); repeatedly take the
  not-yet-finalized node with the smallest best-known distance, declare it
  *final* — its distance can never improve, because any other route to it would
  have to pass through a node with an even larger distance — and *relax* its
  edges: for each outgoing edge, check whether reaching its neighbor through
  this node beats the neighbor's best-known distance, and if so, update it.
  With a min-priority queue picking the next node, the running time is
  $O((V + E) log V)$, and the answer is provably exact whenever weights are
  non-negative — which crossing times always are.
]

#defterm([Priority queue (min-heap)])[
  A data structure supporting "insert with a priority" and "remove the
  minimum-priority element," both in $O(log n)$; a binary heap inside an array
  is the standard implementation. Dijkstra's algorithm spends its entire life
  asking one question — "which unfinished node is currently closest to the
  source?" — and a priority queue is precisely that question, as a data
  structure.
]

Here is the uncomfortable arithmetic that frames the rest of the section.
Dijkstra is correct — and unusable at our scale. A cross-country query over
~100M nodes takes seconds of CPU; Section 2.5 showed that seconds × 20k QPS is
~60,000 cores of pure search. We cannot buy our way out; we must *search less
of the graph*. Each of the next three refinements is a different way of doing
exactly that.

*Refinement 1 — bidirectional Dijkstra.* Run two searches simultaneously: one
forward from the origin, one *backward* from the destination over reversed
edges. Stop when the frontiers meet; the route is the two half-paths joined.
Why does that help? The picture makes it obvious:

#v(0.3em)
#align(center)[
#canvas(h: 4.6cm)[
  // ---- left panel: unidirectional Dijkstra explores a full-radius ball ----
  #place(dx: 0.85cm, dy: 0.35cm, circle(radius: 1.75cm, stroke: 1pt + primary, fill: faint-blue))
  #place(dx: 2.53cm, dy: 2.03cm, circle(radius: 0.07cm, fill: ink))
  #place(dx: 4.28cm, dy: 2.03cm, circle(radius: 0.07cm, fill: ink))
  #glabel(2.42cm, 2.18cm, [A], fg: ink, size: 8pt)
  #glabel(4.20cm, 2.18cm, [B], fg: ink, size: 8pt)
  #glabel(0.6cm, 4.0cm, [unidirectional: explores ≈ $pi d^2$], fg: slate, size: 7.6pt)
  // ---- right panel: bidirectional — two half-radius balls ----
  #place(dx: 7.15cm, dy: 0.60cm, circle(radius: 1.55cm, stroke: 1pt + primary, fill: faint-blue))
  #place(dx: 10.15cm, dy: 0.60cm, circle(radius: 1.55cm, stroke: 1pt + teal, fill: faint-teal))
  #place(dx: 8.63cm, dy: 2.08cm, circle(radius: 0.07cm, fill: ink))
  #place(dx: 11.63cm, dy: 2.08cm, circle(radius: 0.07cm, fill: ink))
  #glabel(8.52cm, 2.23cm, [A], fg: ink, size: 8pt)
  #glabel(11.55cm, 2.23cm, [B], fg: ink, size: 8pt)
  #glabel(7.3cm, 4.0cm, [bidirectional: ≈ $2 pi (d \/ 2)^2 = pi d^2 \/ 2$], fg: slate, size: 7.6pt)
  // annotation
  #glabel(13.3cm, 1.35cm, [search frontiers], fg: slate, size: 7.2pt)
  #glabel(13.3cm, 1.68cm, [meet in the], fg: slate, size: 7.2pt)
  #glabel(13.3cm, 2.01cm, [middle], fg: slate, size: 7.2pt)
]]
#v(0.2em)

The left panel shows the unidirectional search. Dijkstra knows nothing about
where B is, so it explores *everything* within reach of A: a disk whose radius
grows until it touches B. If A and B are distance _d_ apart, that disk has
radius _d_ and — in a roughly planar road network, where node count grows with
area — contains on the order of $pi d^2$ nodes. The right panel shows the
bidirectional search: a blue disk spreading from A and a teal one spreading
backward from B, and the algorithm stops the moment the two frontiers touch.
Each disk has radius only $d \/ 2$, so together they explore about
$2 dot pi (d \/ 2)^2 = pi d^2 \/ 2$ — *half* the nodes. The saving comes from
the quadratic: halving the radius quarters each disk, and two quarter-disks
beat one whole disk. Same provably-exact answer, half the CPU, and the two
searches are trivially run on two threads. A real improvement — and nowhere
near enough.

*Refinement 2 — A\* search.* Look at the left disk again and something should
offend you: Dijkstra explores equally in *all* directions, including straight
away from the destination. Every node it finalizes on the far side of A from B
is provably wasted work. A\* fixes this by reordering the priority queue so the
frontier grows *toward* B instead of uniformly.

#defterm([Heuristic / admissible heuristic])[
  In A\*, each node's queue priority becomes `known distance from source +
  h(node)`, where the _heuristic_ `h` estimates the *remaining* distance to the
  destination. The heuristic is _admissible_ if it never *overestimates* the
  true remaining cost — and admissibility is the whole ballgame: with it, A\*
  keeps Dijkstra's exactness guarantee while pulling the search frontier toward
  the goal, because nodes in promising directions get smaller priorities and
  are popped first. Overestimate even once and you can finalize a node through
  the wrong path; the guarantee dies quietly.
]

For a road network, nature hands us a perfect admissible heuristic: the
*straight-line distance to the destination, divided by the fastest speed
anywhere in the network*. No legal route can beat the crow flying at top
speed, so this `h` never overestimates — it is admissible by construction.
Computing it requires distances between points on a sphere, which needs one
more definition:

#defterm([Haversine distance])[
  The great-circle distance between two latitude/longitude points on a sphere —
  the length of the shortest path over the Earth's surface, "as the crow
  flies." A closed-form trigonometric formula computes it in microseconds;
  Section 2.14 implements it. Haversine is our heuristic's yardstick and, more
  generally, our fallback whenever the question "how far apart are these two
  coordinates?" appears anywhere in the system.
]

*Refinement 3 — hierarchy: mega-segments, then contraction hierarchies.* Even
A\* has a blind spot: it still explores every side street near the origin and
the destination, because near the endpoints the heuristic cannot yet
distinguish promising from unpromising detours. Now think about how *you*
actually drive cross-country: local streets for a minute, then a highway for
three hundred miles, then local streets again. The middle of a long route
almost never touches small roads — and that human observation can be turned
into a mechanism: precompute the hierarchy and let queries climb it.

#defterm([Mega-segment])[
  A precomputed synthetic edge that summarizes a chain of ordinary segments —
  for example, one edge meaning "highway, exit 12 to exit 47, 52 km, ~31
  minutes at current speeds." A long-distance search can then hop between
  on-ramps and off-ramps on mega-segments instead of expanding thousands of
  small ones. The source talk builds its long-range routing this way: segments
  roll up into mega-segments, which roll up further, so a query quickly climbs
  from street level to highway level, crosses the country on a handful of
  edges, and descends again. And because a mega-segment's weight is the *sum*
  of its members' weights, when traffic updates a segment (Section 2.12), the
  change simply *bubbles up* to every mega-segment containing it — the
  hierarchy stays live without being rebuilt.
]

The literature's formal, optimal version of the same idea:

#defterm([Contraction hierarchy (CH)])[
  A preprocessed form of the road graph, built offline in two steps. First,
  order all nodes by importance — highway junctions outrank cul-de-sacs.
  Second, *contract* the nodes in that order: remove a low-importance node,
  and whenever the shortest path between two of its neighbors ran through it,
  insert a *shortcut edge* with the summed weight, so every shortest-path
  distance in the graph is preserved exactly. At query time, run bidirectional
  Dijkstra with one extra rule: only follow edges that go *up* in importance.
  The two upward searches meet at the most important node on the route — and
  because unimportant nodes were contracted away, the search spaces are tiny.
  Preprocessing takes hours and adds ~30–100% more edges; in exchange, queries
  drop from seconds to *microseconds-to-milliseconds* — the roughly 1000×
  speedup that Section 2.5's arithmetic demands. Production engines (OSRM,
  Valhalla, and the systems the source talk gestures at with mega-segments)
  all run variants of this playbook.
]

The full ladder, with the numbers that justify each rung:

#tbl(
  (auto, auto, auto, 1fr),
  header: (hcell[Algorithm], hcell[Preprocessing], hcell[Query time], hcell[Verdict]),
  body: (
    [Dijkstra], [none], [seconds (continental)], [Teaches the principle; too slow to serve],
    [Bidirectional Dijkstra], [none], [~2× faster, still seconds], [Free win; still too slow],
    [A\* + haversine], [none], [often 5–10× faster], [Great for short trips; long trips still expand too much],
    [*Mega-segments / CH*], [hours, offline], [≈ 0.1–1 ms], [*Production answer*: the ~1000× that makes 20k QPS fit on ~20 cores],
  ),
)

#insight([Precomputation is the theme of the whole chapter])[
  Step back and notice what the last three sections have in common. Tiles are
  pre-rendered so reads become cache hits (Section 2.6). The graph is
  pre-contracted so queries touch only highways-in-the-middle (this section).
  Traffic speeds are pre-aggregated per segment so ETAs become table lookups
  (Section 2.12). A maps system is a machine for moving work *off* the request
  path and into batch and stream pipelines that ran earlier. So when an
  interviewer asks "how does it answer so fast?", the honest one-word answer
  is: *earlier*.
]

== API & Protocol Design

Chapter 1 split its API into a control plane and a data plane, and the same
split applies here — with one twist worth savoring: our heaviest "API" is
barely an API at all.

*Tiles are plain GETs — and mostly not ours.* Because the slippy-map scheme is
deterministic, the client computes the $(z, x, y)$ address of every tile in
view by itself (Section 2.14 has the eleven lines) and issues ordinary
`GET /v1/tiles/{z}/{x}/{y}` requests against a tile hostname. Nearly all of
those requests terminate at a CDN edge and never reach our infrastructure. Sit
with that for a second, because it inverts the usual API-design story: the tile
endpoint has *no interesting request parameters*, no session, no state — all
the intelligence lives in the addressing scheme, which the client and the cache
both understand. The best-designed endpoint in this system is the one we barely
operate.

#defterm([Polyline encoding])[
  A compact ASCII encoding of a sequence of coordinates. Google's variant
  encodes latitude/longitude *deltas* as variable-length, base-64-ish text, so
  a 500-point route becomes a few hundred bytes instead of a JSON array of
  floats ten times larger. Routes are transmitted as encoded polylines and
  decoded client-side. The format exists because a route is geometrically huge
  — it crosses a route-length's worth of geography — but must fit inside one
  small, cacheable response.
]

The remaining request/response endpoints are ordinary REST (as defined in
Chapter 1):

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Method], hcell[Path], hcell[Purpose]),
  body: (
    [`GET`], [`/v1/tiles/{z}/{x}/{y}`], [Map tiles; served by CDN edge, origin on miss],
    [`GET`], [`/v1/search?q=&near=lat,lng`], [Place search: text + spatial filter, ranked results],
    [`GET`], [`/v1/search/autocomplete?q=`], [Prefix suggestions as the user types],
    [`POST`], [`/v1/routes`], [Directions: origin, destination, mode, departure time → candidate routes with distance, ETA, ETA-in-traffic, steps, encoded polyline],
    [`POST`], [`/v1/geocode`], [Address → coordinates (and reverse: coordinates → address)],
  ),
)

A route request and its response, so you can see exactly what the routing
engine's output becomes on the wire:

```json
POST /v1/routes
{
  "origin":      { "lat": 37.7749, "lng": -122.4194 },
  "destination": { "lat": 37.3861, "lng": -122.0839 },
  "mode": "driving",
  "depart_at": "now"
}

200 OK
{
  "routes": [{
    "route_id": "rt_9c31",
    "distance_m": 56300,
    "eta_seconds": 2820,
    "eta_in_traffic_seconds": 3450,
    "polyline": "a~l~Fjk~uOwIb@_...",
    "steps": [
      { "instruction": "Head north on Market St",
        "segment_ids": ["seg_7712", "seg_7713"],
        "distance_m": 400, "eta_seconds": 61 }
    ]
  }]
}
```

Two fields in that response deserve a pause. `eta_seconds` versus
`eta_in_traffic_seconds` is Section 2.7's design made visible: the first is the
route at free-flow weights, the second at *current* weights, and showing both
is what lets the UI say "10 minutes slower than usual." And each step carries
`segment_ids` — the route is not just a picture, it is a list of the exact
road segments the user will traverse, which is precisely what the navigation
session needs to track progress and what the traffic pipeline needs to match
this user's GPS updates back to the roads they are actually on.

Navigation (FR-5) is a *session*, not a request: the phone streams its position
up, and the server streams guidance down, for as long as the trip lasts. That
is a bidirectional, long-lived, low-latency channel — in other words, exactly
the WebSocket data plane Chapter 1 built, reused verbatim:

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Message], hcell[Direction], hcell[Payload & semantics]),
  body: (
    [`nav_start`], [client → server], [`{route_id, auth}` — begin the session on the chosen route],
    [`location_update`], [client → server], [`{lat, lng, speed_mps, heading_deg, t}` — one GPS fix, every ~5 s; drives guidance *and* the traffic pipeline],
    [`instruction`], [server → client], [`{text, voice, distance_to_maneuver_m}` — the next turn, delivered early enough to speak],
    [`eta_update`], [server → client], [`{eta_seconds, remaining_m}` — refreshed as segment weights move],
    [`reroute`], [server → client], [`{reason, new_route}` — deviation, or a newly faster alternative],
    [`nav_end`], [either], [Arrived, cancelled, or the connection dropped],
  ),
)

Two protocol notes before we move on. First, look at `location_update`
carefully: it is *one stream feeding two masters*. The navigation service uses
it to guide this user, right now; the traffic pipeline uses it — anonymized and
aggregated — to update everyone's edge weights. Section 2.12 draws that fork as
a picture. Second, navigation is the one place in the whole system where *we*
push *down* to a moving phone, and that raises a plumbing question the diagram
in Section 2.11 must answer: with millions of WebSocket gateways, which one
holds this user's connection? The connection manager, introduced there, exists
to answer exactly that.

== Data Model & Storage

Six entity families, six different access patterns — which is this chapter's
excuse to define a term you should reach for whenever one database is asked to
be four things:

#defterm([Polyglot persistence])[
  Using different storage engines for different access patterns within one
  system, instead of forcing every entity into a single database. The cost is
  real — operational complexity, more moving parts, more consistency questions
  — but the benefit is that each workload gets the structure it actually needs.
  A maps system is the canonical case for it, as the table below shows: our six
  entities want six different shapes, and pretending otherwise would punish
  every one of them.
]

#tbl(
  (auto, 1.5fr, 1.15fr),
  header: (hcell[Entity], hcell[Contents], hcell[Store]),
  body: (
    [`Tile`], [`(z,x,y)` → rendered image or vector geometry], [Object store behind the CDN; *content-addressed* so identical tiles are stored once],
    [`Place`], [name, category, address, location, ratings, hours], [Text-inverted index × spatial index; ~200M records],
    [`Segment`], [geometry, length, road class, speed limit, turn restrictions], [Wide-column store (Cassandra-class), sharded by geography; read-heavy, batch-written],
    [`Road graph`], [adjacency lists + current weights + shortcuts], [*In RAM* on routing nodes; rebuilt/swapped from the segment store + traffic cache],
    [`Traffic`], [`segment_id` → current average speed, sample count, updated-at], [In-memory key-value cache (Redis-class) with a TTL — absence means "no fresh data," triggering the historical fallback],
    [`Historical speeds`], [`segment_id × (day-of-week, time bucket)` → average speed], [Analytics warehouse, batch-computed nightly from the GPS archive],
    [`Nav session`], [route, progress along it, last fix, ETA], [In-memory on the navigation node; ephemeral like Chapter 1's presence data],
  ),
)

Three ideas in this table are the ones interviewers reward, so let us pull them
out of the rows. First, tiles are *content-addressed*: Section 2.5's 29 PB
nightmare collapses because duplicate oceans are stored once, under one hash.
Second, the routing graph lives *in memory* — the stores are only its source of
truth during reloads, never on the request path; that is how route latency
survives its budget. Third, and most elegant: the traffic cache's TTL *is* the
freshness guarantee. A segment whose entry has expired simply stops claiming
live data, and the system degrades to historical patterns without anyone
handling an error. Absence as a signal is a pattern worth stealing.

== High-Level Architecture

Section 2.4 promised that this system has separate planes with separate NFRs;
here they are, in one picture. The *read plane* (tiles, search, routes) is
stateless and cache-fronted. The *streaming plane* (GPS in, traffic out) is a
pipeline. Navigation sits astride both. Then we will walk the picture slowly.

#v(0.3em)
#align(center)[
#canvas(h: 7.6cm)[
  // clients + entry
  #node(0.2cm, 0.1cm, 3.2cm, 0.95cm, [Clients \ mobile · web], fill: faint, edge: slate)
  #node(0.2cm, 1.7cm, 3.2cm, 0.8cm, [CDN edge (tiles)], fill: faint-blue, edge: primary, size: 7.6pt)
  #node(4.6cm, 0.1cm, 3.4cm, 0.8cm, [API gateway], fill: white, edge: slate, size: 8pt)
  #node(4.6cm, 1.7cm, 3.4cm, 0.8cm, [WS gateway fleet], fill: white, edge: primary, size: 8pt)
  // read-plane services
  #node(9.2cm, 0.0cm, 3.5cm, 0.75cm, [Search service], fill: white, edge: primary, size: 7.8pt)
  #node(9.2cm, 0.9cm, 3.5cm, 0.75cm, [Routing service \ (CH graph in RAM)], fill: white, edge: primary, size: 7.4pt)
  #node(9.2cm, 1.85cm, 3.5cm, 0.75cm, [Navigation service], fill: faint-blue, edge: primary, size: 7.8pt)
  // streaming plane
  #node(4.6cm, 3.3cm, 3.4cm, 0.75cm, [Location ingestion], fill: white, edge: teal, size: 7.8pt)
  #node(9.2cm, 3.3cm, 3.5cm, 0.75cm, [Event stream \ (Kafka-class)], fill: white, edge: teal, size: 7.2pt)
  #node(13.4cm, 3.3cm, 3.2cm, 0.75cm, [Stream processors \ map-match · avg speed], fill: white, edge: teal, size: 7.2pt)
  // stores
  #node(0.2cm, 5.6cm, 3.4cm, 0.85cm, [Tile object store \ content-addressed], fill: white, edge: slate, size: 7.2pt)
  #node(4.6cm, 5.6cm, 3.4cm, 0.85cm, [Segment store \ Cassandra-class], fill: white, edge: slate, size: 7.4pt)
  #node(9.2cm, 5.6cm, 3.4cm, 0.85cm, [Traffic cache \ Redis-class + TTL], fill: white, edge: teal, size: 7.4pt)
  #node(13.4cm, 5.6cm, 3.2cm, 0.85cm, [Historical speeds \ warehouse], fill: white, edge: slate, size: 7.2pt)
  #node(13.4cm, 0.9cm, 3.2cm, 0.75cm, [Connection manager \ user → gateway], fill: white, edge: amber.darken(15%), size: 7.2pt)
  // arrows — read plane
  #arrow(1.8cm, 1.08cm, 1.8cm, 1.66cm)
  #arrow(3.45cm, 2.1cm, 4.55cm, 2.1cm)
  #arrow(3.45cm, 0.6cm, 4.55cm, 0.5cm)
  #arrow(8.05cm, 0.45cm, 9.15cm, 0.4cm)
  #arrow(8.05cm, 0.62cm, 9.15cm, 1.25cm)
  #arrow(8.05cm, 2.1cm, 9.15cm, 2.2cm)
  // arrows — streaming plane
  #arrow(6.3cm, 2.53cm, 6.3cm, 3.26cm, color: teal)
  #arrow(8.05cm, 3.67cm, 9.15cm, 3.67cm, color: teal)
  #arrow(12.75cm, 3.67cm, 13.35cm, 3.67cm, color: teal)
  #arrow(15.0cm, 4.08cm, 11.0cm, 5.55cm, color: teal)
  #arrow(10.9cm, 5.55cm, 10.9cm, 1.68cm, color: teal, dashed: true)
  // stores access
  #arrow(6.3cm, 5.55cm, 10.4cm, 1.68cm, dashed: true, color: slate)
  #arrow(1.9cm, 2.53cm, 1.9cm, 5.55cm, dashed: true, color: slate)
  #arrow(12.6cm, 1.68cm, 14.9cm, 1.68cm, color: amber.darken(15%))
  // labels
  #glabel(0.5cm, 2.62cm, [origin on miss], size: 6.8pt)
  #glabel(4.9cm, 2.85cm, [location_update], fg: teal.darken(12%), size: 6.8pt)
  #glabel(11.15cm, 4.3cm, [segment speeds], fg: teal.darken(12%), size: 6.8pt)
  #glabel(10.95cm, 4.95cm, [weights], fg: teal.darken(12%), size: 6.8pt)
  #glabel(12.75cm, 1.42cm, [lookup], fg: amber.darken(20%), size: 6.8pt)
  #glabel(7.0cm, 5.15cm, [graph reload], size: 6.8pt)
  #glabel(0.2cm, 6.7cm, [Read plane: stateless, cache-fronted. Streaming plane: GPS in → traffic out. Dashed: control/reload paths.], size: 7pt)
]]
#v(0.2em)

This diagram has a lot of moving parts, so let us walk it in the order data
actually flows, and make sure every arrow earns its place.

*The read plane, top half.* Begin at the top left. When a client pans the map,
its tile requests drop almost immediately into the *CDN edge* box directly
below — the vertical arrow — and, for 95%+ of them, the journey ends right
there. Only on a cache miss does the long dashed arrow down the left margin
carry the request to our *tile object store*, the "origin on miss." The base
map, remember, changes weekly at worst, so even a stale edge copy is safe to
serve while revalidating.

Everything else the client asks for — search, routes, navigation — flows right
through the two gateway boxes. Plain REST calls (search, routes) go through the
*API gateway*, which does the ordinary edge work: authentication, rate
limiting, routing. Long-lived navigation connections go through the *WebSocket
gateway fleet*, Chapter 1's stateless connection-holders reused without
changes. From the API gateway, three short arrows fan out to the read-plane
services: the *search service* answers place queries over its text × spatial
index; the *routing service* answers directions on its in-memory CH graph; and
the *navigation service* — highlighted, because it is the session-ful one —
runs the per-user guidance state machine of Section 2.13.

*The streaming plane, middle row.* Now watch a GPS fix take the other road.
While navigating, the phone sends a `location_update` every five seconds; the
teal arrow carries it down from the WS gateway to *location ingestion*, whose
job is to absorb 3M updates per second, validate them, strip identity, and
absorb bursts so processing never sees them. From there the fix enters the
*event stream* — a durable, partitioned log (defined properly in Section 2.12)
— and then the *stream processors*, which do the two hard jobs: map-matching
the noisy fix onto a real segment, and folding its speed into that segment's
running average.

*Where the two planes meet.* The long teal arrow from the stream processors
down to the *traffic cache* is the handshake between the planes: per-segment
speeds land in a small, hot, TTL-governed cache. And then the arrow labeled
"weights" — dashed teal, from the traffic cache up to the routing service — is
the single most important arrow in the whole design: it is how *reality changes
the answers*. Every few minutes, the routing engine's edge weights are
re-read from the cache, so the very next route request routes around a jam that
formed ninety seconds ago. Meanwhile a second dashed arrow, "graph reload,"
runs from the segment store up to the routing service: that is the slow path
by which new roads and edited geometry enter the in-memory graph on a
periodic rebuild-and-swap cycle.

*The amber plumbing, top right.* One small box is easy to overlook: the
*connection manager*. When the navigation service decides a user needs a
`reroute` push, it knows *what* to send but not *where the user's socket
lives* among thousands of gateways. The connection manager is the registry
that answers — the amber "lookup" arrow — and Section 2.13 shows how it is
kept honest.

Finally, the bottom row of stores should look familiar from Section 2.10 —
they are drawn in the same left-to-right order as the workloads above them:
tiles at the far left behind the CDN, segments under ingestion, the traffic
cache under the stream processors, and the *historical speeds* warehouse at
the far right, quietly batch-computed each night from the day's GPS archive
and standing ready as the fallback whenever live data runs dry.

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [CDN edge], [Serve ~95%+ of tile requests], [Tiles are static and skewed — the textbook cache workload (Section 2.6)],
    [API gateway], [Auth, rate limiting, routing for REST endpoints], [Stateless; also the paid-API front door, where per-customer quotas are enforced],
    [Search service], [Text × spatial place lookup], [Read-heavy over a slowly-changing index; replicas scale it],
    [Routing service], [Compute routes + ETAs on the CH graph], [Holds the graph *in RAM*; scales by region shards and replicas (Section 2.15)],
    [WS gateway fleet], [Hold millions of navigation connections], [Stateless connection holders, exactly as in Chapter 1],
    [Navigation service], [Per-session guidance: progress, instructions, ETA refresh, reroutes], [Stateful per session — but sessions are small and independent],
    [Connection manager], [Registry: user → which gateway], [So the navigation service can push `reroute` to the right socket (Section 2.13)],
    [Location ingestion], [Absorb 3M updates/s, validate, anonymize], [A buffer that decouples phone bursts from processing (Section 2.12)],
    [Event stream], [Durable, replayable pipe of GPS updates], [Defined in Section 2.12; lets many consumers read the same firehose],
    [Stream processors], [Map-match pings to segments; average speeds; write traffic cache; bubble weights up mega-segments], [The batch-quality work of traffic, done continuously],
  ),
)

== Deep Dive: The Live Traffic Loop

This is the subsystem that turns "a map" into "*current* conditions," and it is
the heart of the source talk. It is also a beautiful example of a feedback loop
in systems form: the product's own users generate the data that improves the
product's answers for everyone. Let us define the four moving parts first, then
follow one GPS update until it changes a stranger's ETA.

#defterm([Event streaming platform (Kafka-class)])[
  A distributed, durable, append-only log organized into *topics*. Producers
  append events; any number of independent *consumers* read them at their own
  pace, and the log remembers, so a slow or crashed consumer resumes where it
  left off. Topics are *partitioned* — we partition by geographic key, a
  geohash prefix — so hundreds of consumer instances process the stream in
  parallel, each owning a disjoint slice of the world. For us it absorbs the
  3M updates/second, decouples ingestion from processing, and — because it is
  replayable — lets us rebuild derived state after failures. Chapter 4 studies
  this kind of platform as a design problem in its own right.
]

#defterm([Stream processing])[
  Computing over data *as it arrives* — event by event, or in small windows —
  rather than in scheduled batch runs over stored data. The distinction matters
  because freshness demands it: a nightly batch over today's GPS data would give
  you yesterday's traffic. Here, every GPS update is map-matched and folded
  into a per-segment running average within seconds of leaving the phone.
]

#defterm([Map-matching])[
  Snapping a noisy GPS fix to the road segment the vehicle is most likely
  *actually* on. Raw GPS is wrong by 5–50 meters — enough to place a car on the
  wrong street, on a parallel frontage road, or inside a building. The
  production-standard approach models the trace as a *hidden Markov model*:
  hidden states are the candidate segments near each fix, emission scores
  measure how close the fix is to each candidate, and transition scores measure
  how plausible the implied movement between consecutive candidates is; the
  Viterbi algorithm then finds the most likely segment sequence. Map-matching
  is why the traffic pipeline's first stage is a *processor*, not a database
  write — the raw fix is evidence, not fact.
]

#defterm([Sliding window])[
  A moving time interval over a stream — "the last 15 minutes," recomputed as
  time advances. A per-segment sliding-window average of observed speeds is our
  operational definition of "current speed": old enough data falls out of the
  window and stops influencing the present, so the average tracks reality with
  a bounded lag and a bounded memory. Section 2.14 implements the window in
  about twenty lines.
]

Now the loop itself, end to end:

#v(0.3em)
#align(center)[
#canvas(h: 4.4cm)[
  #node(0.2cm, 0.3cm, 3.1cm, 0.9cm, [Navigating phones \ 15M at peak], fill: faint, edge: slate, size: 7.6pt)
  #node(4.3cm, 0.3cm, 3.0cm, 0.9cm, [Ingestion → topic \ partitioned by geo], fill: white, edge: teal, size: 7.4pt)
  #node(8.3cm, 0.3cm, 3.0cm, 0.9cm, [Map-matching \ fix → segment_id], fill: white, edge: teal, size: 7.4pt)
  #node(12.3cm, 0.3cm, 3.6cm, 0.9cm, [Speed aggregator \ sliding window/segment], fill: white, edge: teal, size: 7.4pt)
  #node(12.3cm, 2.3cm, 3.6cm, 0.85cm, [Traffic cache \ segment → avg speed, TTL], fill: white, edge: teal, size: 7.2pt)
  #node(8.3cm, 2.3cm, 3.0cm, 0.85cm, [Routing graphs \ update edge weights], fill: faint-blue, edge: primary, size: 7.2pt)
  #node(4.3cm, 2.3cm, 3.0cm, 0.85cm, [Traffic tiles \ re-render, short TTL], fill: white, edge: primary, size: 7.4pt)
  #arrow(3.35cm, 0.75cm, 4.25cm, 0.75cm, color: teal)
  #arrow(7.35cm, 0.75cm, 8.25cm, 0.75cm, color: teal)
  #arrow(11.35cm, 0.75cm, 12.25cm, 0.75cm, color: teal)
  #arrow(14.1cm, 1.23cm, 14.1cm, 2.26cm, color: teal)
  #arrow(12.25cm, 2.72cm, 11.35cm, 2.72cm, color: teal)
  #arrow(8.25cm, 2.72cm, 7.35cm, 2.72cm, color: teal)
  #glabel(4.6cm, 1.35cm, [3M updates/s], fg: teal.darken(12%), size: 6.9pt)
  #glabel(8.5cm, 3.3cm, [weights bubble up to mega-segments], fg: slate, size: 6.9pt)
  #glabel(0.2cm, 3.7cm, [Every few minutes, reality → graph. ETAs and reroutes on new routes then use fresh weights automatically.], size: 7pt)
]]
#v(0.2em)

Trace one fix through the picture. Top row, left to right: your phone, mid-
navigation, emits a GPS fix every five seconds; ingestion absorbs it (with 3M
of its siblings every second) and drops it onto the geo-partitioned topic; the
map-matcher consumes it and decides which segment you are really on; the
aggregator folds your speed into that segment's sliding window. Now the loop
turns downward: the fresh per-segment average lands in the *traffic cache*,
TTL ticking. From there the picture forks left along the bottom row, and the
fork is the two places "current speed" becomes user-visible. One arrow feeds
the *routing graphs*: edge weights update, mega-segment weights bubble up as
their members change, and every *subsequent* route request quietly routes
around the jam — no code path changed, because traffic was always just
weights. The other arrow feeds the *traffic tiles*: segment speeds become
green/yellow/red classes rendered into the overlay layer with its one-minute
TTL, so the next pan shows the jam in red. Reality to pixels to routing
decisions, in a few minutes, forever.

Three design details carry the interview discussion of this loop:

+ *Speed, not position, is the aggregate.* Per segment and window, we average
  the *speeds* of map-matched vehicles. One slow vehicle is noise — a delivery
  van at the curb with its hazards on; the average over dozens of vehicles in
  fifteen minutes is signal. And notice the happy alignment: because only
  segment statistics survive, nobody's individual trace is stored in the
  traffic cache at all. Privacy and accuracy, for once, pull in the same
  direction.
+ *Sparse segments fall back to history.* At 3 a.m. on a rural road, the window
  holds too few samples to trust. Below a minimum count, we blend toward the
  *historical* speed for that segment, day-of-week, and time-of-day — and
  traffic is blessedly periodic, so Tuesday-8 a.m. looks remarkably like last
  Tuesday-8 a.m. The rule of thumb: live data where it exists, patterns where
  it does not, the speed limit as the floor of last resort.
+ *Third-party feeds are scored, not trusted.* We also ingest incident and flow
  feeds from external providers — and the talk is explicit about the
  discipline: validate each feed against our own observed reality. If a
  provider claims congestion on a corridor where our measured speeds never
  dropped, the claim is wrong; a provider wrong too often is down-weighted or
  ignored at the organization level. Every external signal is guilty until
  statistically innocent.

The same machinery, one more time, paints the traffic overlay of FR-6 —
segment speeds become color classes, rendered into a *separate tile layer* with
a TTL of a minute or two: short-lived tiles stacked on the long-lived base
map, each layer cached at its own freshness, exactly as Section 2.6's TTL
discussion promised.

== Deep Dive: The Turn-by-Turn Navigation Session

A navigation session is a small state machine per user, held in the navigation
service: `ON_ROUTE → OFF_ROUTE_SUSPECTED → REROUTING → ON_ROUTE → ARRIVED`.
Each incoming `location_update` advances it through four steps, and each step
has a design decision embedded in it:

+ *Project.* Map-match the fix onto the planned route's polyline: how far along
  the route is the user, and how far *off* it? Projection turns raw geography
  into progress.
+ *Guide.* From progress, emit the next `instruction` early enough to be
  spoken — "in 300 meters, turn right" must arrive with time for the voice to
  say it and the driver to change lanes. Guidance is scheduled by distance to
  the maneuver, not by wall-clock.
+ *Refresh.* Recompute the ETA over the remaining segments using *current*
  weights from the traffic cache; push an `eta_update` only when the value
  moves by more than a small threshold. Users notice a jumping ETA and read it
  as the product being confused; hysteresis here is a *feature*, not sloppiness.
+ *Reroute.* If the fix sits beyond a distance threshold from the polyline
  *and* heading disagrees with the route — *sustained* across a few consecutive
  updates, because one bad fix must never trigger a reroute (GPS noise is
  constant) — recompute from the current position and push `reroute` with the
  new route. Section 2.14 implements this exact decision as the
  `RerouteFilter`.

The push path needs one piece of plumbing we deferred: the navigation service
knows *what* to send but not *where the user's socket lives*. The *connection
manager* — a replicated key-value registry mapping `user_id → gateway_id` —
answers that question: gateways register each connection on connect and remove
it on drop; the navigation service looks the user up and hands the message to
the right gateway. If the registry entry is stale because a gateway died, the
client's reconnect registers a fresh one within seconds, and at worst one push
is retried. This is Chapter 1's stateless-gateway story, completed with its
directory.

#pitfall([Rerouting on a single GPS fix])[
  GPS in a downtown canyon can teleport a user two blocks sideways for one
  update and then snap back. A reroute fired on that ghost fix is a terrible
  user experience — the voice confidently announces a new route to a driver who
  never left the old one — and it has a subtler cost: it *pollutes the traffic
  pipeline* with a phantom slow-down on a road the user never touched. Both
  loops therefore consume map-matched, sustained signals, never raw single
  fixes. The same discipline, applied twice, in two subsystems that never meet.
]

#tip([Navigation availability is a degradation story, not an uptime story])[
  Four nines on the navigation path does not mean "the server never dies" — at
  our scale the server dies daily. It means *the phone copes when it does*. The
  client caches its route, its upcoming tiles, and its step list; if the
  session drops, guidance continues locally from the last known state while a
  new session is established in the background. Saying "the client is the
  final fallback layer of the server" out loud is exactly the kind of answer
  the 99.99% requirement is fishing for.
]

== Deep Dive: Rust Reference Implementations

Four pieces of this chapter are small enough — and interview-critical enough —
to show in full: tile addressing, the routing core, the traffic window, and the
reroute decision. As you read them, keep mapping each one back to the section
it implements; that mapping is what turns "I read about it" into "I can build
it."

=== Tile addressing: lat/lng → tile → quadkey

The slippy-map formulas of Section 2.6, plus the quadkey encoding that makes
tiles prefix-searchable:

```rust
/// Web-Mercator slippy-map addressing (Section 2.6).

/// Which tile (x, y) at `zoom` contains this lat/lng?
pub fn lat_lng_to_tile(lat: f64, lng: f64, zoom: u8) -> (u32, u32) {
    let n = 2f64.powi(zoom as i32);              // tiles per axis: 2^z
    let x = ((lng + 180.0) / 360.0 * n) as u32;
    let lat = lat.to_radians();
    let y = ((1.0 - lat.tan().asinh() / std::f64::consts::PI) / 2.0 * n) as u32;
    let max = n as u32 - 1;
    (x.min(max), y.min(max))                     // clamp the antimeridian edge
}

/// The same address as a quadkey: one digit per zoom level, '0'..='3',
/// interleaving y/x bits from the most significant down. Neighboring tiles
/// share prefixes — a quadkey IS a quadtree path — so a plain sorted
/// key-value store can answer "all tiles in this area" as a range scan.
pub fn quadkey(x: u32, y: u32, zoom: u8) -> String {
    let mut key = String::with_capacity(zoom as usize);
    for level in (0..zoom).rev() {
        let mask = 1u32 << level;
        let mut digit = 0u8;
        if x & mask != 0 { digit += 1; }
        if y & mask != 0 { digit += 2; }
        key.push((b'0' + digit) as char);
    }
    key
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_world_is_tile_zero() {
        assert_eq!(lat_lng_to_tile(0.0, 0.0, 0), (0, 0));
    }

    #[test]
    fn san_francisco_zoom_16() {
        // Verified against the slippy-map formulas.
        assert_eq!(lat_lng_to_tile(37.7749, -122.4194, 16), (10482, 25331));
        assert_eq!(quadkey(10482, 25331, 16), "0230102033330032");
    }

    #[test]
    fn bing_canonical_quadkey() {
        // The documentation example: tile (3, 5) at level 3 -> "213".
        assert_eq!(quadkey(3, 5, 3), "213");
    }
}
```

Pause on the quadkey, because it is the bridge from map-serving to place
search. Since a quadkey *is* a quadtree path, all tiles inside a region share
the region's key as a prefix — so if you index every place under the quadkey of
its location, then "places near me" becomes "places whose key shares my tile's
prefix," widened one ring of neighbors at a time. A two-dimensional spatial
query collapses into a string-prefix range scan, and any sorted key-value store
can serve it. Chapter 12's geohash index is the same trick with a different
alphabet.

=== The routing core: haversine, Dijkstra, A\*

Section 2.8's algorithm ladder, executable. Weights are integer *milliseconds*
of expected crossing time — exact arithmetic, and exactly what the traffic loop
updates:

```rust
use std::cmp::Reverse;
use std::collections::BinaryHeap;

pub type NodeId = u32;

/// One directed segment leaving a node (Section 2.7).
#[derive(Clone, Copy, Debug)]
pub struct Edge {
    pub to: NodeId,
    pub millis: u32, // expected crossing time — the weight traffic moves
}

/// In-memory adjacency-list road graph (Section 2.7).
pub struct RoadGraph {
    pub adj: Vec<Vec<Edge>>,
    pub lat: Vec<f64>, // node coordinates, for haversine and A*
    pub lng: Vec<f64>,
}

/// Great-circle distance in meters (Section 2.8).
pub fn haversine_m(a: (f64, f64), b: (f64, f64)) -> f64 {
    const R: f64 = 6_371_000.0; // Earth radius, meters
    let (la1, la2) = (a.0.to_radians(), b.0.to_radians());
    let dla = (b.0 - a.0).to_radians();
    let dlo = (b.1 - a.1).to_radians();
    let h = (dla / 2.0).sin().powi(2) + la1.cos() * la2.cos() * (dlo / 2.0).sin().powi(2);
    2.0 * R * h.sqrt().asin()
}

/// Dijkstra: exact shortest path by total crossing time.
pub fn dijkstra(g: &RoadGraph, source: NodeId, target: NodeId) -> Option<(u64, Vec<NodeId>)> {
    let mut dist = vec![u64::MAX; g.adj.len()];
    let mut prev = vec![u32::MAX; g.adj.len()];
    let mut heap = BinaryHeap::new();
    dist[source as usize] = 0;
    heap.push(Reverse((0u64, source)));
    while let Some(Reverse((d, u))) = heap.pop() {
        if u == target { break; }             // popped => finalized => optimal
        if d > dist[u as usize] { continue; } // stale heap entry
        for e in &g.adj[u as usize] {
            let nd = d + e.millis as u64;     // relax the edge
            if nd < dist[e.to as usize] {
                dist[e.to as usize] = nd;
                prev[e.to as usize] = u;
                heap.push(Reverse((nd, e.to)));
            }
        }
    }
    if dist[target as usize] == u64::MAX { return None; }
    let mut path = vec![target];              // walk predecessors back
    while *path.last().unwrap() != source {
        path.push(prev[*path.last().unwrap() as usize]);
    }
    path.reverse();
    Some((dist[target as usize], path))
}

/// A*: the same search, re-prioritized by an admissible heuristic —
/// remaining straight-line distance at the fastest plausible speed, so it
/// never overestimates (and, on a road graph, is *consistent*, which is what
/// licenses the early exit when the target is popped).
pub fn astar(g: &RoadGraph, source: NodeId, target: NodeId) -> Option<(u64, Vec<NodeId>)> {
    const MAX_SPEED_MPS: f64 = 70.0; // ~250 km/h: faster than any legal road
    let t = target as usize;
    let h = |n: NodeId| -> u64 {
        let i = n as usize;
        (haversine_m((g.lat[i], g.lng[i]), (g.lat[t], g.lng[t])) / MAX_SPEED_MPS * 1000.0) as u64
    };
    let mut dist = vec![u64::MAX; g.adj.len()];
    let mut prev = vec![u32::MAX; g.adj.len()];
    let mut heap = BinaryHeap::new();
    dist[source as usize] = 0;
    heap.push(Reverse((h(source), 0u64, source))); // (priority, dist, node)
    while let Some(Reverse((_, d, u))) = heap.pop() {
        if u == target { break; }
        if d > dist[u as usize] { continue; }
        for e in &g.adj[u as usize] {
            let nd = d + e.millis as u64;
            if nd < dist[e.to as usize] {
                dist[e.to as usize] = nd;
                prev[e.to as usize] = u;
                heap.push(Reverse((nd + h(e.to), nd, e.to)));
            }
        }
    }
    if dist[t] == u64::MAX { return None; }
    let mut path = vec![target];
    while *path.last().unwrap() != source {
        path.push(prev[*path.last().unwrap() as usize]);
    }
    path.reverse();
    Some((dist[t], path))
}
```

Read the two functions side by side and you will see that A\* *is* Dijkstra —
same loop, same relaxation, same predecessor walk — with a single difference:
what the heap orders by. That is the honest way to present A\* in an interview:
not a new algorithm, but Dijkstra with its priorities aimed at the goal. And
here is the test that demonstrates the chapter's slogan — *traffic is just
edge weights that move*:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny city: two ways from node 0 to node 4, edges ~1.1–1.6 km.
    ///   0 -> 1 -> 2 -> 4 :  60 s +  60 s +  60 s = 180 s
    ///   0 -> 3 -> 4      :  30 s + 120 s        = 150 s   (normally fastest)
    /// (Times are consistent with the A* speed cap of 70 m/s, so the
    /// haversine heuristic stays admissible on this graph.)
    fn tiny_city() -> RoadGraph {
        let mut adj = vec![Vec::new(); 5];
        let e = |adj: &mut Vec<Vec<Edge>>, from: u32, to: u32, millis: u32| {
            adj[from as usize].push(Edge { to, millis });
            adj[to as usize].push(Edge { to: from, millis }); // two-way streets
        };
        e(&mut adj, 0, 1, 60_000);
        e(&mut adj, 1, 2, 60_000);
        e(&mut adj, 2, 4, 60_000);
        e(&mut adj, 0, 3, 30_000);
        e(&mut adj, 3, 4, 120_000);
        RoadGraph {
            adj,
            lat: vec![0.0, 0.0, 0.01, -0.01, 0.0],   // rough grid around origin
            lng: vec![0.0, 0.01, 0.01, 0.01, 0.02],
        }
    }

    #[test]
    fn dijkstra_and_astar_agree() {
        let g = tiny_city();
        assert_eq!(dijkstra(&g, 0, 4).unwrap().0, 150_000);
        let (millis, path) = astar(&g, 0, 4).unwrap();
        assert_eq!(millis, 150_000);
        assert_eq!(path, vec![0, 3, 4]);
    }

    #[test]
    fn traffic_reroutes() {
        let mut g = tiny_city();
        // Congestion report: the 3 -> 4 segment now takes 600 s.
        g.adj[3].iter_mut().find(|e| e.to == 4).unwrap().millis = 600_000;
        g.adj[4].iter_mut().find(|e| e.to == 3).unwrap().millis = 600_000;
        // No code path changes — the "traffic-aware" router is the same
        // algorithm reading different weights.
        assert_eq!(dijkstra(&g, 0, 4).unwrap().1, vec![0, 1, 2, 4]);
    }
}
```

The `traffic_reroutes` test is the one to internalize. We mutate two weights —
a jam forms on the 3→4 segment — and the *same unmodified Dijkstra* now returns
the long way around. No "traffic mode," no special case: the router does not
know traffic exists. That is what Section 2.7 bought by making weight mean
expected crossing time.

=== The traffic window: from GPS fixes to edge weights

The aggregator at the heart of Section 2.12: a per-segment sliding window of
observed speeds, the live/historical blend, and the weight the graph stores.

```rust
use std::collections::VecDeque;

/// Per-segment sliding-window speed average (Section 2.12).
pub struct SpeedWindow {
    samples: VecDeque<(u64, f64)>, // (timestamp_secs, observed speed m/s)
    window_secs: u64,              // e.g. 15 * 60
}

impl SpeedWindow {
    pub fn new(window_secs: u64) -> Self {
        Self { samples: VecDeque::new(), window_secs }
    }

    pub fn add(&mut self, now: u64, speed_mps: f64) {
        self.samples.push_back((now, speed_mps));
        self.evict(now);
    }

    fn evict(&mut self, now: u64) {
        while let Some(&(t, _)) = self.samples.front() {
            if now.saturating_sub(t) > self.window_secs { self.samples.pop_front(); }
            else { break; }
        }
    }

    /// Current average, or None when there is too little live data —
    /// the caller then blends in the historical pattern (Section 2.12).
    pub fn average(&mut self, now: u64, min_samples: usize) -> Option<f64> {
        self.evict(now);
        if self.samples.len() < min_samples { return None; }
        let sum: f64 = self.samples.iter().map(|&(_, s)| s).sum();
        Some(sum / self.samples.len() as f64)
    }
}

/// Effective speed for a segment: live average where we trust it,
/// the historical pattern for this day/time otherwise, and never above
/// the posted limit (we do not route people as if speeding were planned).
pub fn effective_speed(live: Option<f64>, historical: f64, limit: f64) -> f64 {
    live.unwrap_or(historical).min(limit)
}

/// The edge weight the routing graph stores (Section 2.7): expected
/// crossing time. Clamped away from zero so weights stay finite and
/// Dijkstra's non-negativity requirement is never endangered.
pub fn weight_millis(segment_length_m: f64, speed_mps: f64) -> u32 {
    (segment_length_m / speed_mps.max(0.5) * 1000.0) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_evicts_old_samples() {
        let mut w = SpeedWindow::new(900);          // 15-minute window
        w.add(1_000, 30.0);                          // highway at full speed
        w.add(1_700, 8.0);                           // jam begins
        w.add(1_800, 9.0);
        // The t=1000 sample is now 800 s old: inside the window.
        assert_eq!(w.samples.len(), 3);
        w.add(2_000, 10.0);
        // t=1000 is 1000 s old: evicted. Average over the jam only.
        let avg = w.average(2_000, 3).unwrap();
        assert!((avg - 9.0).abs() < 0.01);
    }

    #[test]
    fn sparse_segments_fall_back_to_history() {
        let mut w = SpeedWindow::new(900);
        w.add(100, 22.0);                            // one car at 3 a.m.
        assert_eq!(w.average(200, 10), None);        // not enough samples
        // Historical pattern says 20 m/s here at this day/time; limit 25.
        assert_eq!(effective_speed(None, 20.0, 25.0), 20.0);
        // Live data says 30 m/s, but we never plan on speeding.
        assert_eq!(effective_speed(Some(30.0), 20.0, 25.0), 25.0);
    }

    #[test]
    fn weight_is_crossing_time() {
        assert_eq!(weight_millis(1_000.0, 10.0), 100_000); // 1 km at 10 m/s
        assert!(weight_millis(1_000.0, 0.0) > 0);          // clamped, finite
    }
}
```

Notice how `average` returning `Option<f64>` makes the sparse-data fallback
*type-safe*: "we don't have enough live data" is not a sentinel value or an
error — it is `None`, and the compiler forces the caller to handle it. And
`weight_millis` clamping speed away from zero is a quiet act of care: a segment
gridlocked to a standstill must produce a huge weight, not a division by zero
or an infinite crossing time that breaks Dijkstra's assumptions.

=== The reroute decision

Section 2.13's state machine, reduced to its durable core: distance from the
planned polyline, sustained across fixes. (Distance uses a local flat-earth
approximation — within a few hundred meters of the route, the Earth's curvature
is below GPS noise; production systems run the full map-matching of Section
2.12 here.)

```rust
/// Approximate meters-per-degree at a given latitude: 111.32 km per degree
/// of latitude everywhere; longitude degrees shrink with cos(latitude).
fn meters_per_deg(lat: f64) -> (f64, f64) {
    (111_320.0, 111_320.0 * lat.to_radians().cos())
}

/// Distance from point p to segment a-b, in meters (local approximation).
fn point_segment_m(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let (m_lat, m_lng) = meters_per_deg(p.0);
    let (px, py) = (p.1 * m_lng, p.0 * m_lat);
    let (ax, ay) = (a.1 * m_lng, a.0 * m_lat);
    let (bx, by) = (b.1 * m_lng, b.0 * m_lat);
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    let t = if len2 == 0.0 { 0.0 } else {
        (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0)
    };
    let (cx, cy) = (ax + t * dx, ay + t * dy);   // closest point on a-b
    ((px - cx).powi(2) + (py - cy).powi(2)).sqrt()
}

/// Distance from a fix to the nearest point anywhere on the route polyline.
pub fn distance_to_route_m(p: (f64, f64), route: &[(f64, f64)]) -> f64 {
    route.windows(2)
        .map(|w| point_segment_m(p, w[0], w[1]))
        .fold(f64::MAX, f64::min)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Guidance { OnRoute, OffRouteSuspected, Reroute }

/// The hysteresis filter: ONE noisy fix must never trigger a reroute
/// (Section 2.13's pitfall). `strikes` counts consecutive off-route fixes.
pub struct RerouteFilter {
    pub distance_threshold_m: f64, // e.g. 40 m
    pub required_consecutive: u8,  // e.g. 3 fixes
    strikes: u8,
}

impl RerouteFilter {
    pub fn new(distance_threshold_m: f64, required_consecutive: u8) -> Self {
        Self { distance_threshold_m, required_consecutive, strikes: 0 }
    }

    pub fn update(&mut self, fix: (f64, f64), route: &[(f64, f64)]) -> Guidance {
        if distance_to_route_m(fix, route) > self.distance_threshold_m {
            self.strikes += 1;
        } else {
            self.strikes = 0;
        }
        if self.strikes >= self.required_consecutive { Guidance::Reroute }
        else if self.strikes > 0 { Guidance::OffRouteSuspected }
        else { Guidance::OnRoute }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A straight eastbound route along lat 37.0.
    fn route() -> Vec<(f64, f64)> { vec![(37.0, -122.0), (37.0, -121.9)] }

    #[test]
    fn on_route_fix_stays_quiet() {
        let mut f = RerouteFilter::new(40.0, 3);
        assert_eq!(f.update((37.0001, -121.95), &route()), Guidance::OnRoute);
    }

    #[test]
    fn sustained_deviation_reroutes() {
        let mut f = RerouteFilter::new(40.0, 3);
        // ~56 m north of the route: beyond threshold.
        let lost = (37.0005, -121.95);
        assert_eq!(f.update(lost, &route()), Guidance::OffRouteSuspected);
        assert_eq!(f.update(lost, &route()), Guidance::OffRouteSuspected);
        assert_eq!(f.update(lost, &route()), Guidance::Reroute);
    }

    #[test]
    fn one_ghost_fix_recovers() {
        let mut f = RerouteFilter::new(40.0, 3);
        assert_eq!(f.update((37.0005, -121.95), &route()), Guidance::OffRouteSuspected);
        assert_eq!(f.update((37.0, -121.95), &route()), Guidance::OnRoute);
    }
}
```

The three tests are the three user stories: the normal drive (stay quiet), the
genuine wrong turn (three strikes, then reroute), and the downtown ghost fix
(suspect once, recover, never bother the driver). Forty lines of Rust, and the
entire "what should happen when the user misses a turn?" discussion has a
falsifiable answer.

== Scaling & Geographic Sharding

Chapter 1 defined sharding and warned that the art is in the key. Here the key
chooses itself: *geography*. Every workload in this system is naturally located
— tiles are places, segments are places, GPS fixes are places — and that makes
the sharding table almost suspiciously clean:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Tier], hcell[Sharding strategy], hcell[Why]),
  body: (
    [Tiles], [No sharding logic at all — the `(z,x,y)` address space partitions naturally; CDN edges cache by URL], [Addressing *is* the partition scheme; popularity skew does the rest],
    [Road graph], [Partitioned by region (continent → subregion); each shard is a full in-memory copy of its region's CH graph, replicated], [A route is overwhelmingly inside one region; replicas add both capacity and failover],
    [Cross-region routes], [Solved hierarchically: mega-segments cross region borders at a handful of highway gateways], [The hierarchy of Section 2.8 doubles as the distributed-systems answer],
    [GPS stream], [Topic partitioned by geohash prefix; each stream-processor instance owns a disjoint set of cells], [Map-matching and aggregation are embarrassingly parallel over geography],
    [Traffic cache], [Sharded by `segment_id` hash; total size ~500 MB], [Tiny, hot, and latency-critical — keep it in memory, close to routing],
    [Place index], [Replicated per region; sharded by quadkey prefix within a region], [Search is read-heavy and geographically scoped (Section 2.14)],
  ),
)

Linger on the third row, because it is the one that looks like a problem and is
not. "What about a route from Lisbon to Warsaw — two graph shards?" feels like
it should force distributed queries. It does not, and the reason is beautiful:
Section 2.8's hierarchy, which we built to make search fast, *also* makes
distribution unnecessary. A Lisbon–Warsaw query climbs to the highway level
inside the origin region's shard, crosses on mega-segments that span the border
at a handful of highway gateways, and descends inside the destination shard.
The algorithmic optimization and the scaling strategy are the same object.

#insight([Geography is a forgiving shard key])[
  Compare geography to Chapter 1's key — the document — and you will see why
  this chapter's scaling story is calm. Documents grow legs: a shared document
  can go viral, concentrate fifty editors, and migrate between owners.
  Geography does none of that. A region's road graph changes on the scale of
  weeks; its traffic weights change on the scale of minutes but are
  *regenerated* in place, never migrated. The one genuinely hot spot — a
  stadium emptying at 11 p.m. — is absorbed *inside* one partition by the
  aggregation pipeline, not spread across the system. When your shard key is
  this well-behaved, most of distributed systems' horror stories simply do not
  apply to you.
]

== Failure Modes & Recovery

The enumeration, before the interviewer asks for it — with the pattern from
Chapter 1 still in force: stateless things are replaced, stateful things are
rebuilt from the log, and degradation is designed rather than improvised.

#tbl(
  (auto, 1fr),
  header: (hcell[Failure], hcell[Handling]),
  body: (
    [WS gateway dies], [Clients reconnect to any gateway; the connection manager re-registers them; the navigation service resumes pushes to the new socket. Unacknowledged client updates are retried and deduplicated — Chapter 1's idempotency discipline, unchanged.],
    [Navigation node dies], [Sessions are small: a route plus progress along it. The client's reconnect carries its last known position; a fresh node rebuilds the session from the route store and continues. The user sees a pause, not a crash.],
    [Stream backpressure / Kafka lag], [Freshness degrades first and *visibly*: per-segment entries age past their TTL, and the system slides to historical speeds automatically — Section 2.12's fallback is the degradation mode, by design, not by apology. Recovery replays the log.],
    [Traffic cache loss], [Rebuilt from the stream within one window (~15 min); historical speeds serve in the meantime and nobody pages anyone.],
    [Routing node dies], [Each region shard is replicated; traffic shifts to a replica. A lost node reloads its graph from the segment store plus the traffic cache (Section 2.10).],
    [Tile origin down], [The CDN keeps serving — 95%+ of requests never knew the origin existed. `stale-while-revalidate` semantics make even expired tiles safe, since the base map changes weekly at worst.],
    [Bad or spoofed GPS input], [Per-segment sample thresholds ignore singletons; per-source scoring quarantines systematically wrong feeds (Section 2.12).],
    [Full region outage], [The phone is the last fallback: cached route, tiles, and step list keep guiding offline (Section 2.13) while sessions re-home to another region.],
  ),
)

Read the third row twice. In most systems, "the pipeline is behind" is a
page-worthy emergency. Here it is a *designed, user-visible, self-healing
degradation*: colors fade to historical patterns, ETAs lean on Tuesday-8 a.m.
instead of right now, and when the pipeline catches up, the live colors come
back. The freshness NFR is what makes this softness possible — a system whose
promise is "recent" can always fall back to "typical."

== Trade-offs & Alternatives

The ledger, benefit against cost, as always:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Benefit purchased], hcell[Cost accepted]),
  body: (
    [Vector tiles over raster], [~50% fewer bytes; restyle without re-render; smooth zoom], [The client's GPU does the work; a raster fallback must exist for old clients],
    [CH / mega-segments over plain A\*], [~1000× query speedup; the only way 20k QPS fits a small fleet], [Hours of preprocessing; shortcut weights must be rebuilt or bubbled up when traffic moves — extra machinery (Section 2.8)],
    [WebSocket push for navigation], [Reroutes and ETA updates arrive instantly; one connection also carries GPS upstream], [Millions of long-lived connections to hold, and a registry (the connection manager) to find them],
    [Hybrid live + historical traffic], [Coverage everywhere; graceful under sparse data and pipeline lag], [Two data paths to keep consistent, and blending logic to get right],
    [Quadkey/geohash indexing], [Proximity becomes a string-prefix range scan in ordinary key-value stores], [Cell-boundary artifacts — a place just across a boundary is missed unless you always query the neighbor ring too],
    [Precompute over on-demand render], [Tiles and hierarchy make reads O(cache hit)], [A planet of batch jobs to run, version, and roll back],
  ),
)

The last row is the chapter's thesis wearing a cost column. Moving work off the
request path bought us every latency number we promised — and the bill arrives
as operational surface area: batch renderers, graph rebuilds, warehouse jobs,
each with versions and rollbacks and monitors of their own. There is no free
millisecond; there are only milliseconds you paid for in advance.

== Observability & SLOs

The accuracy requirement (±10% ETA) cannot be an aspiration; it must be a
measured, per-city, per-hour number. That needs a metric:

#defterm([MAPE (mean absolute percentage error)])[
  The average of `|predicted − actual| / actual` over many predictions — the
  standard accuracy metric for forecasts, and the natural SLI for ETA quality.
  Here we are unusually lucky: per *completed* trip, we know both the ETA we
  gave and the travel time that reality delivered, so ETA MAPE is measurable
  exactly, per city, per hour, per route class. The source talk is emphatic on
  this point and it deserves the emphasis: you cannot improve what you do not
  score, and ETA accuracy is the metric this product lives by.
]

Beyond MAPE, the dashboard that keeps this system honest: *route acceptance
rate* — how often users actually drive the recommended route, because a
recommendation nobody takes is a signal something is wrong with the routes (the
talk's analytics discussion makes exactly this point); reroute rate per
session, which is route quality measured by contradiction; tile cache hit ratio
and origin QPS, guarding the 95% promise of Section 2.6; route latency p50/p99;
pipeline lag from fix to weight update, the freshness SLI in seconds; median
age of live segment speeds; and navigation session drop-and-recovery times,
the 99.99% promise measured where the user feels it.

== Interview Wrap-Up

The likely follow-ups, with the shape of a strong answer for each:

- _"Offline maps?"_ — Ship regional bundles (tiles plus the contracted graph)
  to the device; routing runs locally; traffic and reroute quality silently
  degrade until reconnect. Notice that everything we precomputed server-side is
  *exactly* what the bundle contains — the theme of precomputation, one final
  time.
- _"Public transit?"_ — A *time-dependent* graph, where edges exist only when
  a vehicle does. Dijkstra generalizes, but production transit uses
  schedule-based algorithms (RAPTOR and friends). Name it, admire it, do not
  build it in the interview.
- _"GPS noise in urban canyons?"_ — The hidden-Markov map-matching of Section
  2.12, plus sensor fusion: accelerometer, gyroscope, and wheel ticks where the
  vehicle offers them.
- _"Better ETAs?"_ — Features into a learned model: current and historical
  speeds, weather, events, turn and signal penalties; graph neural networks can
  model congestion *spreading* along the road graph. Google reported up to ~50%
  ETA-error reductions in some cities from exactly this move. Say the number as
  motivation, then defend the simple hybrid of Section 2.12 as the baseline any
  model must beat.
- _"Walking and cycling?"_ — Same graph, same algorithms, different edge
  eligibility and weights: stairs, bike lanes, no highways. The design's
  generality *is* the answer.
- _"Location privacy?"_ — Aggregate, don't store: segment statistics instead of
  traces, retention limits on raw updates, and minimum sample counts that
  double as k-anonymity for sparse segments. Section 2.12's design made the
  private choice the convenient one — point that out.

*If you remember five things:*

+ The map is a precomputed pyramid of addressable squares; the CDN, not your
  fleet, serves it.
+ Roads are a time-weighted directed graph, and *traffic is just edge weights
  that move*.
+ Dijkstra is exact and unusable; bidirectional and A\* are free wins;
  hierarchy (mega-segments, contraction hierarchies) is the ~1000× that turns
  an algorithm into a product.
+ Live traffic is a streaming pipeline: GPS fix → map-match → per-segment
  windowed average → weights and overlay tiles, with history as the fallback.
+ Navigation correctness lives on the phone: the client caches the route and
  survives the server.

== Summary & Further Reading

We designed a maps and navigation service for 1B monthly users, and — if the
chapter did its job — every piece felt *derived* rather than invented: a
pre-rendered, CDN-served tile pyramid addressed by `(z, x, y)` and quadkeys; a
time-weighted road graph held in memory and searched with an algorithm ladder
that ends at contraction hierarchies; a live traffic loop that turns 3M GPS
updates per second into per-segment speeds, edge weights, and overlay tiles,
with historical patterns as the fallback; and a turn-by-turn navigation service
that guides, refreshes ETAs, and reroutes with hysteresis — degrading
gracefully to the phone when the network, or we, fail.

*Primary source for this chapter:*
- #link("https://www.youtube.com/watch?v=1pmcoh4hc_A")[*"13: Google Maps" — Systems Design Interview Questions With Ex-Google SWE (Jordan has no life)*] — the walkthrough this chapter expands.

*Foundations worth reading:*
- The OSRM and Valhalla open-source routing engines — contraction hierarchies in production code, not just papers.
- Geisberger et al., _Exact Routing in Large Road Networks Using Contraction Hierarchies_ (2008) — the CH formulation.
- Newson & Krumm, _Hidden Markov Map Matching Through Noise and Sparseness_ (2009) — the map-matching standard.
- Google's S2 geometry library documentation, and Uber's H3 — the real spatial indexes behind quadkey-style addressing (Chapter 12 uses H3's geohash cousin directly).
- The Bing Maps tile system documentation — the canonical quadkey reference.
- Google DeepMind's write-up on learning ETAs with graph neural networks (2020) — the ML direction for Section 2.19's follow-up.

== Chapter 2 Glossary

A one-glance index of every term this chapter defined. Chapter 1's glossary is
assumed; later chapters assume both.

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning in one line]),
  body: (
    [ETA], [Predicted travel time / arrival time; the quality bar of this chapter],
    [Freshness], [Age of the data behind an answer; traffic targets minutes],
    [Map tile], [Fixed 256×256 square of map; the unit of storage, cache, transfer],
    [Zoom level], [Scale integer _z_; each step splits every tile into four],
    [Slippy-map scheme], [Deterministic (z, x, y) tile addressing over Web Mercator],
    [Quadkey], [Tile address as a digit string; a quadtree path, prefix-searchable],
    [CDN], [Planet-wide edge caches that absorb static reads near the user],
    [TTL / hit ratio], [How long cache entries may live / fraction of requests they absorb],
    [Content addressing], [Identical tiles (oceans) stored once, by content hash],
    [Polyline encoding], [Compact ASCII encoding of a route's coordinate sequence],
    [Graph], [Nodes + edges; directed and weighted for roads],
    [Segment], [One directed road piece between nodes; the unit of traffic],
    [Adjacency list], [Per-node outgoing-edge lists; the in-memory graph layout],
    [Shortest path], [Minimum-total-weight route; with time weights, the fastest path],
    [Dijkstra's algorithm], [Exact breadth-by-distance search with a priority queue],
    [Priority queue], [O(log n) "give me the current minimum" structure],
    [Bidirectional search], [Two half-searches meeting mid-route; ~half the work],
    [A\* / heuristic], [Dijkstra steered by a remaining-distance estimate],
    [Admissible heuristic], [Never overestimates; preserves exactness],
    [Haversine distance], [Great-circle distance between coordinates],
    [Mega-segment], [Precomputed synthetic edge summarizing a segment chain],
    [Contraction hierarchy], [Node-importance ordering + shortcuts; μs–ms queries],
    [Kafka-class stream], [Durable partitioned event log; decouples and replays],
    [Stream processing], [Computing over data as it arrives, not in batch],
    [Map-matching], [Snapping noisy GPS fixes to the true road segment],
    [Sliding window], [Moving time interval defining "current" speed per segment],
    [Polyglot persistence], [Different engines for different access patterns],
    [Connection manager], [Registry of which gateway holds which user's socket],
    [MAPE], [Mean absolute percentage error; the ETA accuracy SLI],
  ),
)

#v(1.2em)
#align(center)[#text(fill: slate, size: 9.5pt)[
  — End of Chapter 2 · Next: Chapter 3 —
]]
