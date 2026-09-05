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
  routes and ETAs are computed, and how live traffic feeds back into both. This
  chapter follows the same arc, deepened with full definitions, capacity
  mathematics, protocol specifications, and Rust reference implementations.
]

#v(0.4em)

== The Problem Statement

The interviewer looks up and says:

#block(inset: (left: 14pt), stroke: (left: 2pt + primary), above: 0.9em, below: 0.9em)[
  #text(style: "italic", size: 10.5pt)[
    "Design Google Maps. Users should be able to look at a map, search for
    places, and get directions from A to B — with an estimated time of arrival
    that accounts for current traffic."
  ]
]

Where Chapter 1's problem hid its difficulty behind a familiar CRUD interface,
this one hides its difficulty behind a familiar _picture_. A map feels like
content — something you serve, like an image. Directions feel like a lookup —
something you query, like a database. Neither is true. The map is a planet-sized
rendering problem, directions are a graph algorithm running at planetary scale,
and "current traffic" means the system's answers change *under you every few
minutes*, driven by a firehose of GPS signals from millions of moving phones.
Three genuinely hard subsystems — geospatial serving, large-scale graph search,
and real-time stream processing — share one interview.

#defterm([ETA (estimated time of arrival)])[
  The system's prediction of how long a journey from A to B will take, usually
  expressed as a duration or an arrival clock time. An ETA is a *prediction*, not
  a measurement: it must be computed before the journey happens, from a model of
  the road network plus everything currently known about conditions on it. ETA
  accuracy is the quality bar this whole chapter is judged against — Section 2.4
  makes it a formal requirement and Section 2.18 shows how to measure it.
]

== Scope & Clarifying Questions

Never design the prompt you were handed; design the prompt you *negotiated*.
Google Maps is a dozen products wearing one icon, so the first job is to shrink
it. A strong opening exchange looks like this:

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
  Most candidates ask about users and features; few ask *"what data do we get to
  see?"* That single question unlocks this entire problem: the answer (GPS
  updates from phones) is what makes live traffic possible at all. In a real
  interview, the questions that reveal *inputs* are worth as much as the
  questions that reveal *scale*.
]

== Functional Requirements

Chapter 1 defined functional and non-functional requirements; recall that FRs
are what the system must *do*. Our scoped functional requirements:

+ *FR-1 — Map rendering.* The user can view an interactive map of the world and
  pan and zoom it smoothly, from a whole-planet view down to individual streets.
+ *FR-2 — Place search.* The user can find places by name, address, or category
  ("coffee near me") and see them on the map.
+ *FR-3 — Directions.* The user can request a route between two points and
  receives a good route: distance, step-by-step instructions, and a path drawn
  on the map.
+ *FR-4 — ETA.* Every route comes with a travel-time estimate that reflects
  *current* conditions, not just speed limits.
+ *FR-5 — Turn-by-turn navigation.* The user can start a navigation session and
  receives timely spoken/visual instructions, a live ETA that updates en route,
  and an automatic new route if they stray from the planned path.
+ *FR-6 — Traffic overlay.* The map shows current congestion (green/yellow/red)
  on roads, fresh to within a few minutes.

Out of scope, stated explicitly: Street View and satellite imagery, public
transit timetables, offline maps, business-owner tooling, and social features.

== Non-Functional Requirements

#defterm([Freshness])[
  The age of the information behind an answer, measured from when reality
  changed to when the system's output reflects it. A traffic overlay that shows
  speeds from an hour ago is *stale*; our target is that any road's displayed
  condition reflects measurements from the last few minutes. Freshness is the
  NFR that makes this problem a *streaming* system rather than a static one.
]

Four qualities dominate, stated as targets:

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
  Notice that "the system" has no single latency or availability number. Tile
  serving is a massive, cacheable *read* workload where 100 ms matters and a
  stale tile is harmless. Routing is a *compute* workload where one second is
  generous but the algorithm must be exact. The traffic pipeline is a *write*
  workload where a few minutes of lag degrade quality, not correctness. Saying
  "it depends which plane you mean" — and then naming the planes — is a senior
  answer. Chapter 1 drew the same lesson with its control plane / data plane
  split.
]

== Back-of-the-Envelope Estimation

Chapter 1 defined back-of-the-envelope estimation; the discipline is identical —
state assumptions, write them down, invite correction.

*Assumptions:*

- 1B MAU, ~200M DAU. Each daily user views ~60 map tiles worth of panning,
  searches ~2 places, and requests ~3 routes per day.
- 15M concurrent navigation sessions at peak; each phone uploads one GPS update
  every ~5 seconds while navigating; one update ≈ 150 bytes on the wire.
- The world's routable road network is on the order of *300 million directed
  edges* (two directions per road piece, worldwide).
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
  Three conclusions drive everything that follows. First, tile traffic is
  enormous but *the content barely changes* — a perfect caching workload;
  Section 2.6 exists to make 95%+ of those 700k QPS vanish into a CDN. Second,
  the road graph (~20 GB) fits in the RAM of a handful of machines, so routing
  is an *in-memory* problem — but 20k route QPS × ~3 CPU-seconds for a naive
  shortest-path search would need *60,000 CPU cores*, which no fleet absorbs;
  Section 2.8's whole purpose is to shave those 3 seconds down to ~1
  millisecond, at which point ~20 cores suffice. Third, 3M GPS updates per
  second is far too much for any request/response design — it demands a
  streaming pipeline, which Section 2.12 builds.
]

== Core Challenge I: Serving the Map

A user opens the app and sees their city. They drag the map; new streets slide
in. They pinch; the view dives from the whole country to one neighborhood. Each
of those moments requires the *right piece of the planet, rendered, in tens of
milliseconds*. Rendering the world on the fly for every gesture of 200 million
daily users is impossible; the entire solution rests on one idea: *precompute
the map as tiny, independently addressable squares, and cache them everywhere.*

#defterm([Map tile])[
  A small, fixed-size square of the map — conventionally 256×256 pixels (as an
  image) or the equivalent bundle of geometry (as data) — covering a specific
  rectangular patch of the Earth's surface. A screen full of map is assembled
  from a grid of tiles, like mosaic pieces. Tiles are the unit of storage,
  caching, and transfer for every mainstream map service.
]

#defterm([Zoom level])[
  The map's scale, expressed as an integer _z_ from 0 upward. At zoom 0 the
  *entire world* is one tile. Each step down splits every tile into four
  children, so zoom _z_ has $2^z$ tiles per axis and $4^z$ tiles in total.
  Zoom 5 is roughly a country; zoom 10 a city; zoom 15 a neighborhood; zoom 20
  shows a patch about 38 meters wide at the equator — individual buildings.
]

#defterm([Slippy-map tiling scheme])[
  The near-universal convention for addressing tiles: every tile is identified
  by three integers *(z, x, y)* — its zoom level and its grid coordinates,
  counted from the top-left of the world. The Earth's surface is first
  flattened with the Web Mercator projection (which maps the sphere to a square
  and caps latitude near ±85.05°), then cut into the $2^z times 2^z$ grid.
  Given a latitude/longitude and a zoom, *anyone can compute which tile
  contains it* with a closed-form formula — Section 2.14 implements it. The
  addressing is deterministic, so the client never asks the server "which tiles
  do I need?"; it already knows.
]

The pyramid shape is the whole storage story. Four zooms, drawn:

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

Our estimate said storing *all* of that naively costs ~29 PB. Two observations
make it tractable:

+ *Most tiles are uniform.* Roughly 70% of the planet is ocean; enormous areas
  are desert, ice, or forest. A solid-blue 256×256 square compresses to almost
  nothing — and, crucially, *it is the same square everywhere*. Storing tiles
  content-addressed (Section 2.10) means every identical tile in the world is
  stored *once*; the trillions collapse to the few percent of tiles that
  actually contain roads and labels.
+ *Nobody looks at most of the world, most of the time.* Demand is violently
  skewed toward populated areas and common zooms. That skew is what caching
  feeds on.

#defterm([Content Delivery Network (CDN)])[
  A geographically distributed fleet of *edge caches*: servers in hundreds of
  cities, each holding copies of popular content close to users. A request is
  routed to the nearest edge location; on a *cache hit* the content is served
  locally (single-digit milliseconds, zero load on our infrastructure); on a
  *miss* the edge fetches from our origin once and caches it for the next
  requester. CDNs turn a read-heavy, mostly-static workload into someone else's
  bandwidth.
]

#defterm([TTL (time to live) / cache hit ratio])[
  A cached entry's _TTL_ is how long an edge may serve it before revalidating
  with the origin — the dial between freshness and load. The _hit ratio_ is the
  fraction of requests served from cache. For base map tiles we choose long
  TTLs (days; roads move slowly) and expect hit ratios above 95%; the *traffic
  overlay* tiles of Section 2.12 get TTLs of a minute or two, because stale
  traffic is worthless.
]

#pitfall([Serving tiles from your own fleet])[
  The single most common junior mistake on this problem: drawing a "tile
  service" that renders or reads tiles on demand per request. At 700k peak QPS
  that fleet is vast, slow for distant users, and pointless — the content is
  static and cacheable. The correct shape is: *pre-render tiles offline, push
  them to object storage, put a CDN in front, and let the origin see a
  single-digit percentage of traffic.* Rendering is a batch job, not a request
  path.
]

One design fork is worth naming here and deciding later (Section 2.17): tiles
can be *raster* (pre-rendered images) or *vector* (compact geometry the client
renders on its GPU). We will serve vector tiles to modern clients — roughly
half the bytes, restyleable without re-rendering, and one tile set serves every
zoom-adjacent gesture smoothly — while keeping raster fallbacks for old
clients. Either way, the tiling, addressing, and CDN story is identical.

Place search (FR-2) rides on the same geospatial ideas: a *spatial index* lets
us find "all places inside this patch of Earth" without scanning 200M records.
Section 2.7 defines the indexing structure once, because routing needs it too.

== Core Challenge II: Modeling the Road Network

Directions require a mathematical object we can search. That object is a graph,
built from the road network:

#defterm([Graph / weighted directed graph])[
  A _graph_ is a set of *nodes* connected by *edges*. It is _directed_ when
  edges have a direction (a one-way street is traversable only along its arrow)
  and _weighted_ when every edge carries a number measuring the *cost* of
  crossing it. We model intersections as nodes and stretches of road between
  them as edges, and we call one such directed road piece a *segment*.
]

#defterm([Segment])[
  The atomic unit of the road network: one directed piece of road between two
  nodes, carrying metadata — geometry (the polyline of its shape), length, road
  class (residential, arterial, highway), speed limit, and turn restrictions at
  its far end. Segments are also the unit of *traffic*: when we say "this road
  is slow," we mean "this segment's current crossing time is high," and every
  GPS update we receive is attributed to exactly one segment (Section 2.12).
]

The crucial choice is the edge *weight*. Distance is stable but wrong for
drivers; what users minimize is *time*. So an edge's weight is its *expected
crossing time*: `length / current expected speed`. "Current expected speed" is
where live traffic enters — the weight is `length / speed_limit` on an empty
road, and degrades as Section 2.12's pipeline reports slower observed speeds.
Routing and traffic are thereby one mechanism: *traffic is just edge weights
that move.*

#defterm([Adjacency list])[
  The standard memory layout for sparse graphs: for every node, a list of its
  outgoing edges. Routing graphs are extremely sparse (an intersection has ~3–6
  outgoing segments), so an adjacency list stores ~300M small records — the
  ~20 GB from Section 2.5 — instead of the quadratically-sized matrix a dense
  representation would need. Our routing engine holds adjacency lists *in RAM*;
  there is no database on the per-request path.
]

A subtlety interviewers enjoy: a graph edge cannot express "you may enter this
intersection from Main St but not turn left onto 1st Ave." Turn restrictions
are handled either by splitting nodes (one node per incoming direction, with
only legal turns as edges) or by per-edge metadata the search consults. Either
way, the model — nodes, directed edges, time weights — survives intact.

== Core Challenge III: Shortest Paths at Planetary Scale

#defterm([Shortest path problem])[
  Given a weighted graph and two nodes, find the path between them whose total
  edge weight is minimal. With time-weighted segments, the shortest path is the
  *fastest route*, and its total weight is the route's ETA. This is the single
  computation at the heart of FR-3 and FR-4.
]

The canonical algorithm, and the one the interviewer expects you to derive:

#defterm([Dijkstra's algorithm])[
  Explores the graph outward from the source in order of increasing distance
  from it. Maintain for each node the best known distance (initially ∞, 0 for
  the source); repeatedly take the not-yet-finalized node with the smallest
  best-known distance, declare it final, and *relax* its edges — for each
  outgoing edge, check whether reaching its neighbor through this node beats
  the neighbor's best-known distance, and if so update it. With a min-priority
  queue selecting the next node, the running time is $O((V + E) log V)$. It is
  provably exact for non-negative weights — and crossing times are always
  non-negative.
]

#defterm([Priority queue (min-heap)])[
  A data structure supporting "insert with a priority" and "remove the
  minimum-priority element," both in $O(log n)$. A binary heap inside an array
  is the standard implementation. Dijkstra's algorithm spends its life asking
  "which unfinished node is currently closest?" — exactly this operation.
]

Dijkstra is correct — and unusable here. A cross-country query on ~100M nodes
takes seconds of CPU; Section 2.5 showed that times 20k QPS is ~60,000 cores.
Three refinements, each a layer of the same idea — *search less of the graph*:

*Refinement 1 — bidirectional Dijkstra.* Run two searches simultaneously: one
forward from the origin, one *backward* from the destination over reversed
edges. Stop when the frontiers meet; the route is the two half-paths joined.
Why it helps is geometric:

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

A forward search from A must explore roughly every node within distance _d_ of
A — a ball whose node count grows like the *area* $pi d^2$. Two half-searches
each explore a ball of radius $d \/ 2$; together that is
$2 dot pi (d \/ 2)^2 = pi d^2 \/ 2$ — about *half* the work in a uniform graph,
and better in road networks, where the frontiers approach each other along
highways. Same exact answer, half the CPU, and trivially parallelizable across
two threads.

*Refinement 2 — A\* search.* Dijkstra explores equally in *all* directions —
including straight away from the destination, which is obviously wasted. A\*
steers the search by reordering the priority queue.

#defterm([Heuristic / admissible heuristic])[
  In A\*, each node's queue priority is `known distance from source + h(node)`,
  where the _heuristic_ `h` estimates the remaining distance to the
  destination. The heuristic is _admissible_ if it never *overestimates* the
  true remaining cost. Admissibility preserves Dijkstra's exactness guarantee
  while pulling the search frontier toward the goal — nodes in the right
  direction get popped first.
]

For a road network, the admissible heuristic is the *straight-line distance to
the destination divided by the fastest speed anywhere in the network*: no legal
route can beat the crow flying at top speed, so this `h` never overestimates.
Computing it needs distances between points on a sphere:

#defterm([Haversine distance])[
  The great-circle distance between two latitude/longitude points on a sphere —
  the length of the shortest path over the Earth's surface ("as the crow
  flies"). A closed-form trigonometric formula computes it in microseconds;
  Section 2.14 implements it. Haversine is our heuristic's yardstick and our
  fallback whenever "how far apart are these coordinates?" appears.
]

*Refinement 3 — hierarchy: mega-segments, then contraction hierarchies.* Even
A\* explores every side street near the origin and destination. But observe how
*you* drive cross-country: local streets for a minute, then a highway for three
hundred miles, then local streets again. The middle of a long route almost
never touches small roads. Turn that observation into a mechanism: precompute
and *aggregate*.

#defterm([Mega-segment])[
  A precomputed synthetic edge that summarizes a chain of ordinary segments —
  for example, one edge meaning "highway, exit 12 to exit 47, 52 km, ~31
  minutes at current speeds." A long-distance search can then hop between
  on-ramps and off-ramps on mega-segments instead of expanding thousands of
  small segments. The source talk builds its long-range routing this way:
  segments roll up into mega-segments, which roll up further, so a query
  quickly climbs from street level to highway level, crosses the country on a
  handful of edges, and descends again. Mega-segment weights are sums of member
  segment weights — so when traffic updates a segment (Section 2.12), the
  change *bubbles up* to every mega-segment containing it.
]

The literature's formal, optimal version of the same idea:

#defterm([Contraction hierarchy (CH)])[
  A preprocessed form of the road graph. Offline, order all nodes by importance
  (highway junctions outrank cul-de-sacs) and *contract* them in that order:
  removing a low-importance node, and — whenever the shortest path between two
  of its neighbors ran through it — inserting a *shortcut edge* with the summed
  weight, so all shortest-path distances are preserved. At query time, run
  bidirectional Dijkstra with one rule: only follow edges that go *up* in
  importance. The two upward searches meet at the most important node on the
  route. Preprocessing takes hours and adds ~30–100% more edges; queries drop
  from seconds to *microseconds-to-milliseconds* — the roughly 1000× speedup
  Section 2.5's arithmetic demands. Production engines (OSRM, Valhalla, and
  the systems the source talk gestures at with mega-segments) all run variants
  of this playbook.
]

The full ladder, with the numbers that justify it:

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
  Tiles are pre-rendered so reads are cache hits (Section 2.6); the graph is
  pre-contracted so queries touch only highways-in-the-middle (this section);
  traffic speeds are pre-aggregated per segment so ETAs are table lookups
  (Section 2.12). A maps system is a machine for moving work *off* the request
  path and into batch and stream pipelines. When an interviewer asks "how does
  it answer so fast?", the honest one-word answer is: *earlier*.
]

== API & Protocol Design

Chapter 1 split its API into a control plane and a data plane; the same split
applies, with a twist: our heaviest "API" is not an API at all.

*Tiles are plain GETs — and mostly not ours.* The client computes the
$(z, x, y)$ address of every tile in view (Section 2.6) and issues ordinary
`GET /v1/tiles/{z}/{x}/{y}` requests against a tile hostname. Nearly all of
these terminate at a CDN edge and never reach us. This is why the tile endpoint
has no interesting request parameters: all the intelligence is in the
*addressing scheme*.

#defterm([Polyline encoding])[
  A compact ASCII encoding of a sequence of coordinates — Google's variant
  encodes latitude/longitude deltas as variable-length base-64-ish text, so a
  500-point route is a few hundred bytes instead of a JSON array of floats.
  Routes are transmitted as encoded polylines and decoded client-side; the
  format exists because a route crosses a route-length's worth of geography but
  must fit in one small response.
]

The remaining request/response endpoints (REST, as defined in Chapter 1):

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

A route request and its response:

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

Navigation (FR-5) is a session, not a request: the phone streams its position
up and the server streams guidance down. That is a bidirectional, long-lived,
low-latency channel — the WebSocket data plane from Chapter 1, reused verbatim.

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Message], hcell[Direction], hcell[Payload & semantics]),
  body: (
    [`nav_start`], [client → server], [`{route_id, auth}` — begin the session on the chosen route],
    [`location_update`], [client → server], [`{lat, lng, speed_mps, heading_deg, t}` — one GPS fix, every ~5 s; drives guidance *and* the traffic pipeline],
    [`instruction`], [server → client], [`{text, voice, distance_to_maneuver_m}` — the next turn, delivered early enough to speak],
    [`eta_update`], [server → client], [`{eta_seconds, remaining_m}` — refreshed as segment weights move],
    [`reroute`], [server → client], [`{reason, new_route}` — deviation or a newly faster alternative],
    [`nav_end`], [either], [Arrived, cancelled, or the connection dropped],
  ),
)

Two protocol notes. First, `location_update` is *one stream feeding two
masters*: live guidance for this user, and (anonymized, aggregated) the traffic
pipeline for everyone else — Section 2.12 draws that fork. Second, navigation
is the one place we push *down* to a moving phone, which raises the question
"which gateway holds this user's connection?" — answered by the connection
manager in Section 2.13.

== Data Model & Storage

#defterm([Polyglot persistence])[
  Using different storage engines for different access patterns within one
  system, instead of forcing every entity into one database. The cost is
  operational complexity; the benefit is that each workload gets the structure
  it actually needs. A maps system is the canonical case — our six entities
  below want six different shapes.
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

The ideas interviewers reward here: tiles are *content-addressed* (the 29 PB
problem of Section 2.5 collapses because duplicate oceans are stored once); the
routing graph lives *in memory*, with stores acting only as its source of truth
during reloads; and the traffic cache's TTL *is* the freshness guarantee —
a segment whose entry has expired simply stops claiming live data.

== High-Level Architecture

Section 2.4 promised separate planes; here they are. The *read plane* (tiles,
search, routes) is stateless and cache-fronted. The *streaming plane* (GPS in,
traffic out) is a pipeline. Navigation sits astride both.

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

Component responsibilities, and the reason each exists:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [CDN edge], [Serve ~95%+ of tile requests], [Tiles are static and skewed — the textbook cache workload (Section 2.6)],
    [API gateway], [Auth, rate limiting, routing for REST endpoints], [Stateless; also the paid-API front door, where per-customer quotas are enforced],
    [Search service], [Text × spatial place lookup], [Read-heavy over a slowly-changing index; replicas scale it],
    [Routing service], [Compute routes + ETAs on the CH graph], [Holds the graph *in RAM*; scales by region shards and replicas (Section 2.15)],
    [WS gateway fleet], [Hold millions of navigation connections], [Stateless connection holders, exactly as in Chapter 1],
    [Navigation service], [Per-session guidance: progress, instructions, ETA refresh, reroutes], [Stateful per session but sessions are small and independent],
    [Connection manager], [Registry: user → which gateway], [So the navigation service can push `reroute` to the right socket (Section 2.13)],
    [Location ingestion], [Absorb 3M updates/s, validate, anonymize], [A buffer that decouples phone bursts from processing (Section 2.12)],
    [Event stream], [Durable, replayable pipe of GPS updates], [Chapter 2 defines it below; lets many consumers read the same firehose],
    [Stream processors], [Map-match pings to segments; average speeds; write traffic cache; bubble weights up mega-segments], [The batch-quality work of traffic, done continuously],
  ),
)

== Deep Dive: The Live Traffic Loop

This is the subsystem that turns "a map" into "*current* conditions," and it is
the heart of the source talk. Follow one GPS update until it changes someone's
ETA.

#defterm([Event streaming platform (Kafka-class)])[
  A distributed, durable, append-only log organized into *topics*; producers
  append events, and any number of independent *consumers* read them at their
  own pace. Topics are *partitioned* (we partition by geographic key, e.g.
  geohash prefix) so hundreds of consumer instances process the stream in
  parallel, each owning a disjoint slice of the world. It absorbs our 3M
  updates/second, decouples ingestion from processing, and — because it is
  replayable — lets us rebuild derived state after failures.
]

#defterm([Stream processing])[
  Computing over data *as it arrives*, event by event or in small windows,
  rather than in scheduled batch runs over stored data. Here: every GPS update
  is map-matched and folded into a per-segment running average within seconds
  of leaving the phone.
]

#defterm([Map-matching])[
  Snapping a noisy GPS fix to the road segment the vehicle is most likely
  actually on. Raw GPS is wrong by 5–50 meters — enough to place a car on the
  wrong street or inside a building. The production-standard approach models
  the trace as a *hidden Markov model* (hidden states = candidate segments near
  each fix; emission scores = closeness of fix to segment; transition scores =
  plausibility of the implied movement) and solves it with the Viterbi
  algorithm. Map-matching is why the traffic pipeline's first stage is a
  *processor*, not a database write.
]

#defterm([Sliding window])[
  A moving time interval over a stream — "the last 15 minutes," recomputed as
  time advances. A per-segment sliding-window average of observed speeds is our
  definition of "current speed": old enough data falls out of the window and
  stops influencing the present. Section 2.14 implements the window.
]

The loop, end to end:

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

Three design details carry the interview:

+ *Speed, not position, is the aggregate.* Per segment and window, we average
  the speeds of map-matched vehicles. One slow vehicle is noise (a delivery
  van at the curb); the *average* over dozens of vehicles in 15 minutes is
  signal. This is also why privacy and accuracy align: nobody's individual
  trace is stored in the traffic cache — only segment statistics.
+ *Sparse segments fall back to history.* At 3 a.m. on a rural road, the window
  holds too few samples. Below a minimum count we blend toward the *historical*
  speed for that segment, day-of-week, and time-of-day — Tuesday-8 a.m. traffic
  is remarkably similar to last Tuesday-8 a.m. Live data where it exists,
  patterns where it does not, speed limits as the floor of last resort.
+ *Third-party feeds are scored, not trusted.* We also ingest incident and flow
  feeds from external providers. The talk's discipline: validate each feed
  against our own observed reality — if a provider claims congestion on a
  corridor where our measured speeds never dropped, that claim is wrong, and a
  provider that is wrong often gets *down-weighted or ignored* at the
  organization level. Every external signal is guilty until statistically
  innocent.

The same machinery paints the traffic overlay (FR-6): segment speeds become
green/yellow/red classes, rendered into a *separate tile layer* with a TTL of a
minute or two — short-lived tiles on top of the long-lived base map, each layer
cached at its own freshness.

== Deep Dive: The Turn-by-Turn Navigation Session

A navigation session is a small state machine per user, held in the navigation
service: `ON_ROUTE → OFF_ROUTE_SUSPECTED → REROUTING → ON_ROUTE → ARRIVED`.
Each `location_update` advances it:

+ *Project.* Map-match the fix onto the planned route's polyline: how far along
  the route is the user, and how far *off* it?
+ *Guide.* From progress along the route, emit the next `instruction` early
  enough to be spoken ("in 300 meters, turn right").
+ *Refresh.* Recompute the ETA over the remaining segments using *current*
  weights from the traffic cache; push `eta_update` when it moves by more than
  a small threshold (users notice a jumping ETA; hysteresis is a feature).
+ *Reroute.* If the fix sits beyond a distance threshold from the polyline
  *and* heading disagrees with the route, *sustained* for a few consecutive
  updates (one bad fix must not trigger a reroute — GPS noise is constant),
  recompute from the current position and push `reroute` with the new route.
  Section 2.14 implements this decision.

The push path needs one piece of plumbing: the navigation service knows *what*
to send but not *where the user's socket lives*. The *connection manager* — a
replicated key-value registry mapping `user_id → gateway_id` — answers that:
gateways register each connection on connect and remove it on drop; the
navigation service looks the user up and hands the message to that gateway. If
the registry entry is stale (a gateway died), the client's reconnect registers
a fresh one within seconds, and at worst one push is retried. This is Chapter
1's stateless-gateway story, completed with its directory.

#pitfall([Rerouting on a single GPS fix])[
  GPS in a downtown canyon can teleport a user two blocks sideways for one
  update. A reroute fired on that ghost fix is a terrible user experience — and
  it also *pollutes the traffic pipeline* with a phantom slow-down on a road
  the user never touched. Both loops therefore consume *map-matched, sustained*
  signals, never raw single fixes. The same discipline, twice.
]

#tip([Navigation availability is a degradation story, not an uptime story])[
  Four nines on the navigation path does not mean "the server never dies"; it
  means *the phone copes when it does*. The client caches its route, its
  upcoming tiles, and its step list; if the session drops, guidance continues
  locally from the last known state while a new session is established. Saying
  "the client is the final fallback layer of the server" is exactly the kind of
  answer the 99.99% requirement is fishing for.
]

== Deep Dive: Rust Reference Implementations

Four pieces of this chapter are small enough — and interview-critical enough —
to show in full: tile addressing, the routing core, the traffic window, and the
reroute decision.

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

The quadkey is the bridge to place search: index every place under the quadkey
of its location, and "places near me" becomes "places whose key shares my
tile's prefix," widened one ring of neighbors at a time.

=== The routing core: haversine, Dijkstra, A\*

Section 2.8's algorithm ladder, executable. Weights are integer *milliseconds*
of expected crossing time — exact, and exactly what the traffic loop updates.

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

And the test that demonstrates the chapter's slogan — *traffic is just edge
weights that move*:

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

=== The reroute decision

Section 2.13's state machine, reduced to its durable core: distance from the
planned polyline, sustained across fixes. (Distance uses a local flat-earth
approximation — within a few hundred meters of the route, curvature is noise;
production systems run the full map-matching of Section 2.12 here.)

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

== Scaling & Geographic Sharding

Chapter 1 defined sharding; here the shard key is *geography itself*.

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

#insight([Geography is a forgiving shard key])[
  Unlike user data (Chapter 1's documents), geography does not move, grow
  legs, or go viral. A region's road graph changes on the scale of weeks; its
  traffic weights change on the scale of minutes but are *regenerated*, not
  migrated. The one genuinely hot spot — a stadium emptying at 11 p.m. — is
  absorbed inside one partition by the aggregation pipeline, not spread across
  the system.
]

== Failure Modes & Recovery

#tbl(
  (auto, 1fr),
  header: (hcell[Failure], hcell[Handling]),
  body: (
    [WS gateway dies], [Clients reconnect to any gateway; the connection manager re-registers them; the navigation service resumes pushes to the new socket. Unacked client updates are retried and deduplicated (Chapter 1's idempotency discipline).],
    [Navigation node dies], [Sessions are small (route + progress). The client's reconnect carries its last known position; a fresh node rebuilds the session from the route store and continues. User sees a pause, not a crash.],
    [Stream backpressure / Kafka lag], [Freshness degrades first and *visibly*: per-segment entries age past their TTL, and the system slides to historical speeds automatically — the fallback of Section 2.12 is the degradation mode, by design. Recovery replays the log.],
    [Traffic cache loss], [Rebuilt from the stream within one window (~15 min); historical speeds serve in the meantime.],
    [Routing node dies], [Each region shard is replicated; traffic shifts to a replica. A lost node reloads its graph from the segment store plus the traffic cache (Section 2.10).],
    [Tile origin down], [The CDN keeps serving — 95%+ of requests never noticed the origin existed. `stale-while-revalidate` semantics make even expired tiles safe, since the base map changes weekly at worst.],
    [Bad or spoofed GPS input], [Per-segment sample thresholds ignore singletons; per-source scoring quarantines systematically wrong feeds (Section 2.12).],
    [Full region outage], [The phone is the last fallback: cached route, tiles, and step list keep guiding offline (Section 2.13) while sessions re-home to another region.],
  ),
)

== Trade-offs & Alternatives

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Benefit purchased], hcell[Cost accepted]),
  body: (
    [Vector tiles over raster], [~50% fewer bytes; restyle without re-render; smooth zoom], [Client GPU does the work; a raster fallback must exist for old clients],
    [CH / mega-segments over plain A\*], [~1000× query speedup; the only way 20k QPS fits a small fleet], [Hours of preprocessing; shortcut weights must be rebuilt or bubbled-up when traffic moves — extra machinery (Section 2.8)],
    [WebSocket push for navigation], [Reroutes and ETA updates arrive instantly; one connection also carries GPS upstream], [Millions of long-lived connections to hold and to register (connection manager)],
    [Hybrid live + historical traffic], [Coverage everywhere, graceful under sparse data and pipeline lag], [Two data paths to keep consistent; blending logic to get right],
    [Quadkey/geohash indexing], [Proximity becomes a string-prefix range scan in ordinary KV stores], [Cell-boundary artifacts — always query the neighbor ring too],
    [Precompute over on-demand render], [Tiles and hierarchy make reads O(cache hit)], [A planet of batch jobs to run, version, and roll back],
  ),
)

== Observability & SLOs

#defterm([MAPE (mean absolute percentage error)])[
  The average of `|predicted − actual| / actual` over many predictions — the
  standard accuracy metric for forecasts, and the natural SLI for ETA quality.
  Per *completed* trip, we know both the ETA we gave and the realized travel
  time, so ETA MAPE is measurable exactly, per city, per hour, per route class.
  The source talk is emphatic on this point: you cannot improve what you do
  not score, and ETA accuracy is the metric this product lives by.
]

What we instrument, at minimum: *ETA error distribution* (predicted vs.
realized, per region — the chapter's headline SLI, targeting the ±10% of
Section 2.4); *route acceptance rate* (how often users actually drive the
recommended route — a recommendation nobody takes is a signal something is
wrong with the routes, per the talk's analytics discussion); reroute rate per
session; tile cache hit ratio and origin QPS; route latency p50/p99; pipeline
lag (fix → weight update); traffic freshness (median age of live segment
speeds); navigation session drops and recovery times.

== Interview Wrap-Up

*Likely follow-ups, with one-line answers:*

- _"Offline maps?"_ — Ship regional bundles (tiles + contracted graph) to the
  device; routing runs locally; traffic and reroute quality silently degrade
  until reconnect. Everything we precomputed server-side is exactly what the
  bundle contains.
- _"Public transit?"_ — A *time-dependent* graph (edges exist only when a
  vehicle does); Dijkstra generalizes, but production transit uses
  schedule-based algorithms (RAPTOR and friends). Name it, don't build it.
- _"GPS noise in urban canyons?"_ — The HMM map-matching of Section 2.12, plus
  sensor fusion (accelerometer, gyroscope, wheel ticks where available).
- _"Better ETAs?"_ — Features into a learned model: current and historical
  speeds, weather, events, turn and signal penalties; graph neural networks
  model congestion *spreading* along the road graph. Google reported up to ~50%
  ETA-error reductions in some cities from exactly this move — say the number
  as motivation, then defend the simple hybrid as the baseline it must beat.
- _"Walking and cycling?"_ — Same graph, same algorithms, different edge
  eligibility and weights (stairs, bike lanes, no highways). The design's
  generality is the answer.
- _"Location privacy?"_ — Aggregate, don't store: segment statistics instead
  of traces, retention limits on raw updates, minimum sample counts that double
  as k-anonymity for sparse segments.

*If you remember five things:*

+ The map is a precomputed pyramid of addressable squares; the CDN, not your
  fleet, serves it.
+ Roads are a time-weighted directed graph, and *traffic is just edge weights
  that move*.
+ Dijkstra is exact and unusable; bidirectional and A\* are free wins;
  hierarchy (mega-segments / contraction hierarchies) is the ~1000× that makes
  it a product.
+ Live traffic is a streaming pipeline: GPS fix → map-match → per-segment
  windowed average → weights and overlay tiles, with history as the fallback.
+ Navigation correctness lives on the phone: the client caches the route and
  survives the server.

== Summary & Further Reading

We designed a maps and navigation service for 1B monthly users: a
pre-rendered, CDN-served tile pyramid addressed by `(z, x, y)` and quadkeys; a
time-weighted road graph held in memory and searched with an algorithm ladder
that ends at contraction hierarchies; a live traffic loop that turns 3M GPS
updates per second into per-segment speeds, edge weights, and overlay tiles,
with historical patterns as the fallback; and a turn-by-turn navigation service
that guides, refreshes ETAs, and reroutes with hysteresis — degrading to the
phone when the network or we fail.

*Primary source for this chapter:*
- #link("https://www.youtube.com/watch?v=1pmcoh4hc_A")[*"13: Google Maps" — Systems Design Interview Questions With Ex-Google SWE (Jordan has no life)*] — the walkthrough this chapter expands.

*Foundations worth reading:*
- The OSRM and Valhalla open-source routing engines — contraction hierarchies in production code, not just papers.
- Geisberger et al., _Exact Routing in Large Road Networks Using Contraction Hierarchies_ (2008) — the CH formulation.
- Newson & Krumm, _Hidden Markov Map Matching Through Noise and Sparseness_ (2009) — the map-matching standard.
- Google's S2 geometry library documentation, and Uber's H3 — the real spatial indexes behind quadkey-style addressing.
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
