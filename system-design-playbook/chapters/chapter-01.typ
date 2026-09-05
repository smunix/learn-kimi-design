// ============================================================================
//  CHAPTER 1 — REAL-TIME COLLABORATIVE TEXT EDITOR
//  Source problem: "12: Design Google Docs/Real Time Text Editor"
//  (Systems Design Interview Questions With Ex-Google SWE, Jordan has no life)
// ============================================================================

#import "../template.typ": *

= Designing a Real-Time Collaborative Text Editor

#block(fill: faint, radius: 6pt, inset: (x: 14pt, y: 11pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: slate, tracking: 0.1em)[PROBLEM SOURCE]
  #v(4pt)
  This chapter solves the problem posed in the talk
  #link("https://www.youtube.com/watch?v=YCjVIDv0zQY")[*"12: Design Google Docs / Real Time Text Editor"*]
  from the series _Systems Design Interview Questions With Ex-Google SWE_ (channel:
  _Jordan has no life_, 2024, 47 min). The talk walks the problem in mock-interview
  form — both a high-level design (HLD) and a low-level design (LLD) of the
  concurrency machinery. This chapter follows the same arc, deepened with full
  definitions, capacity mathematics, protocol specifications, and Rust reference
  implementations.
]

#v(0.4em)

== The Problem Statement

The interviewer looks up and says:

#block(inset: (left: 14pt), stroke: (left: 2pt + primary), above: 0.9em, below: 0.9em)[
  #text(style: "italic", size: 10.5pt)[
    "Design a real-time collaborative text editor — something like Google Docs.
    Multiple people should be able to edit the same document at the same time
    and see each other's changes as they happen."
  ]
]

This is one of the richest prompts in the system design canon. It looks like a
CRUD application — until you realize that its heart is a distributed-state
synchronization problem with no trivially correct answer. The prompt deliberately
leaves almost everything open: scale, feature scope, consistency guarantees,
offline behavior. How you close those gaps is most of the grade.

#defterm([High-level design (HLD) / low-level design (LLD)])[
  _HLD_ is the architecture of the whole system: the major services, data stores,
  and network paths, and the justification for each. _LLD_ is the internal
  mechanics of the interesting components: data structures, algorithms, and
  protocols. A strong interview performance does HLD first, then drills into LLD
  for the one or two components that carry the real difficulty — in this problem,
  the concurrency-control core.
]

== Scope & Clarifying Questions

Never design the prompt you were handed; design the prompt you *negotiated*. The
series this chapter draws on runs its interviews as a dialogue, and that is exactly
how a real interview should feel. A strong opening exchange looks like this:

#tbl(
  (auto, 1fr),
  header: (hcell[Speaker], hcell[Dialogue]),
  body: (
    [*Candidate*], ["Are we building plain text editing, or rich text — formatting, embedded images, tables?"],
    [*Interviewer*], ["Plain text is fine. Assume a document is an ordered sequence of characters."],
    [*Candidate*], ["How many collaborators can edit one document simultaneously?"],
    [*Interviewer*], ["Up to 50 concurrent editors per document."],
    [*Candidate*], ["And the total scale — how many users and documents are we designing for?"],
    [*Interviewer*], ["10 million daily active users. Documents themselves can be up to a few hundred kilobytes of text."],
    [*Candidate*], ["Do users need to see each other's cursors and selections live — presence?"],
    [*Interviewer*], ["Yes, cursors and names, like Google Docs shows."],
    [*Candidate*], ["Is offline editing in scope, or can we assume clients are connected while editing?"],
    [*Interviewer*], ["Assume connected for the core design; if time remains, sketch how offline would work."],
    [*Candidate*], ["Do we need version history — the ability to view and restore older revisions?"],
    [*Interviewer*], ["Yes, keep a full history of changes."],
  ),
)

From this exchange we can freeze the scope. Everything later in the chapter traces
back to these decisions, so state them explicitly and get a nod from the
interviewer before moving on.

#block(fill: faint-blue, radius: 6pt, inset: (x: 14pt, y: 10pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: primary, tracking: 0.1em)[AGREED SCOPE]
  #v(4pt)
  Plain-text documents up to ~500 KB; up to *50 concurrent editors per document*;
  *10M daily active users*; live cursors and presence; full version history;
  connected editing for the core design (offline sketched as an extension).
]

#tip([Negotiate scope in both directions])[
  Candidates think clarifying questions only *shrink* scope. They also *expand* it
  deliberately: asking "do we need presence?" signals that you know the feature
  exists and costs something. Offer it, let the interviewer decide, and note the
  cost either way.
]

== Functional Requirements

#defterm([Functional requirement (FR)])[
  A statement of what the system must *do* — an observable behavior a user can
  verify, such as "a user can create a document." Functional requirements define
  the feature set; they say nothing about how fast, how available, or how
  consistent the system must be. Those qualities are _non-functional
  requirements_, defined next.
]

Our scoped functional requirements:

+ *FR-1 — Document management.* Users can create, rename, open, and delete documents.
+ *FR-2 — Real-time collaborative editing.* Multiple users can edit one document
  concurrently; every connected editor sees every other editor's changes within a
  fraction of a second.
+ *FR-3 — Presence.* Each editor sees who else is in the document, with a live
  cursor (and selection) per collaborator, labeled with their name.
+ *FR-4 — Persistence.* A document is never lost because a client disconnects;
  reopening it later yields its latest committed state.
+ *FR-5 — Version history.* Users can browse the full history of a document and
  view or restore any earlier revision.
+ *FR-6 — Sharing & access control.* A document has an owner; the owner grants
  view or edit access to others via a shareable link or explicit invite.

Out of scope (say so explicitly): rich text, comments and suggestions, end-to-end
encryption, and offline-first editing as a core flow.

== Non-Functional Requirements

#defterm([Non-functional requirement (NFR)])[
  A statement of how *well* the system must perform its functions: scale, latency,
  availability, durability, consistency. NFRs are where design decisions actually
  come from — two systems with identical functional requirements (a chat app and a
  payment ledger) can have opposite architectures because their NFRs differ.
]

Three qualities dominate this problem, and they deserve precise vocabulary:

#defterm([Latency])[
  The time between a cause and its observable effect. Two latencies matter here:
  _edit latency_ (my keystroke appears in my own document — must feel instant,
  under ~16 ms, so it must be applied locally without a network round trip) and
  _propagation latency_ (my keystroke appears on a collaborator's screen — our
  target: under ~150 ms for users in the same region).
]

#defterm([Availability])[
  The fraction of time the system is able to serve requests. Editing must remain
  available even when individual servers fail, so no single machine may be
  indispensable. We will aim for the classic "three nines" (99.9% ≈ 8.8 hours of
  downtime per year) for the editing path.
]

#defterm([Consistency / convergence])[
  In a system where many actors mutate shared state concurrently, _consistency_
  describes what guarantees observers get about the state they see. For a
  collaborative editor the crucial guarantee is *convergence*: once the same set
  of edits has been delivered to every replica, every replica must hold the
  *identical document*. If two users could permanently end up looking at different
  text, the product is broken no matter how fast it is. How convergence is
  achieved — without locking the document — is the core challenge of this chapter
  and gets its own section (Section 1.6).
]

The remaining NFRs, stated as targets:

#tbl(
  (auto, 1fr),
  header: (hcell[Quality], hcell[Target]),
  body: (
    [*Propagation latency*], [p50 < 150 ms within a region; p95 < 400 ms cross-region],
    [*Edit (local echo) latency*], [< 16 ms — edits apply locally, synchronously, before any server contact],
    [*Editors per document*], [Up to 50 concurrent, no degradation],
    [*System scale*], [10M DAU; ~1M simultaneous connections at peak],
    [*Durability*], [No committed edit is ever lost (history is the product's memory)],
    [*Availability*], [99.9% for editing; reading a document should survive almost anything],
  ),
)

#insight([Consistency is the NFR that shapes this design])[
  Most interview problems are dominated by throughput (design Twitter) or storage
  (design Dropbox). This one is dominated by *correctness under concurrency*. The
  moment two users type at the same time, you need a mathematical answer to "what
  is the document now?" — Section 1.6 is where the interview is won or lost.
]

== Back-of-the-Envelope Estimation

#defterm([Back-of-the-envelope estimation])[
  Rapid, approximate arithmetic — using round numbers and stated assumptions — that
  sizes a system *before* designing it. Its purpose is not precision; it is to
  discover which constraints bite. A design for 500 messages per second and a
  design for 500,000 messages per second are different systems, and you cannot
  know which one you owe the interviewer until you count.
]

#defterm([DAU / QPS])[
  _DAU_ (daily active users) counts distinct users active in a day. _QPS_ (queries
  per second) is the request rate a system handles. Interview estimates usually
  convert DAU into QPS via an activity model ("each user does X, Y times a day").
]

*Assumptions* (state them, write them down, invite correction):

- 10M DAU; each user actively edits on ~3 documents per day, ~20 minutes per session.
- At peak, ~5% of DAU are simultaneously connected: *500k concurrent connections*
  (we design for 1M to leave headroom).
- An active typist produces ~3 keystroke-operations per second in bursts; averaged
  over a session (reading, thinking, pausing), ~0.5 ops/sec per connected user.
- One operation (a character insert/delete plus metadata) ≈ 250 bytes on the wire.
- Average document size: 20 KB of text (500 KB worst case per our scope).

*Derived numbers:*

#tbl(
  (1.2fr, 0.85fr, 1.35fr),
  header: (hcell[Quantity], hcell[Estimate], hcell[How]),
  body: (
    [Peak edit operations], [≈ 250k ops/sec], [500k conns × 0.5 ops/s],
    [Edit ingress bandwidth], [≈ 60 MB/s], [250k ops/s × 250 B],
    [Operations stored per day], [≈ 2.2B], [~25k ops/s avg × 86,400 s],
    [Operation log growth], [≈ 550 GB/day], [2.2B ops × 250 B],
    [New documents per day], [≈ 3M], [10M users × 0.3],
    [Doc-open QPS (REST)], [≈ 600 avg / 6k peak], [10M × 5 opens/day ÷ 86,400, ×10 peak factor],
    [Connections per WebSocket gateway], [~50k], [commodity servers hold tens of thousands of idle-ish connections],
    [Gateways needed], [~20–40], [1M conns ÷ 25–50k each, plus redundancy],
  ),
)

#insight([What the math tells us])[
  Two facts jump out. First, the *system-wide* write rate (hundreds of thousands
  of ops/sec) is large but utterly *sharded by document*: each document sees at
  most 50 editors producing maybe 150 ops/sec in a frantic burst — trivial for one
  thread. Second, the connection tier is where the scale lives: a million mostly-
  idle WebSocket connections is a capacity problem, not a correctness problem.
  Conclusion: put the hard correctness logic *per document* (where throughput is
  tiny) and make the connection tier *stateless and horizontal* (where throughput
  is huge). This observation drives the entire architecture in Section 1.8.
]

== The Core Challenge: Concurrent Editing

Everything else in this chapter is standard distributed-systems plumbing. This
section is the intellectual center of the problem — and of the source talk.

=== Why naive approaches fail

Suppose two users, Alice and Bob, are editing the document `"GO"` — a two-character
document: `G` at index 0, `O` at index 1. They type *at the same time*:

- *Alice* inserts the character `A` at index 0 (she is turning `"GO"` into `"AGO"`).
- *Bob* deletes the character at index 1 (he is turning `"GO"` into `"G"`).

What should the document be when both edits are delivered? Both users' intentions
are clear, and they do not conflict in spirit: the answer is `"AG"` — Alice's `A`
before the `G`, and the `O` gone. Now examine two naive strategies:

*Naive strategy 1 — lock the document.* Only one editor at a time; everyone else
waits. This is *correct* but useless: it defeats the entire purpose of the product.
Real-time collaboration means no global mutual exclusion.

#defterm([Mutual exclusion / locking])[
  A concurrency-control technique in which a resource may be modified by only one
  actor at a time; others block until the lock is released. Locks serialize work,
  guaranteeing correctness at the cost of parallelism — fatal when the resource is
  a shared document with 50 simultaneous editors.
]

*Naive strategy 2 — last-writer-wins.* Let each edit carry a timestamp; the edit
with the latest timestamp prevails, earlier conflicting edits are discarded.

#defterm([Last-writer-wins (LWW)])[
  A conflict-resolution rule: when two writes to the same datum race, keep the one
  with the later timestamp and drop the other. Simple and fast, but it *loses
  data by design* — one of Alice's or Bob's edits would silently vanish. LWW is
  acceptable for overwritten fields (a profile picture), never for merged text.
]

Applying LWW to our example: if Bob's delete "wins", Alice's `A` disappears. If
Alice's insert "wins", Bob's delete is lost and the `O` resurrects. Neither user
did anything wrong, yet one of their intentions was destroyed. And naive
*position-based* application is worse still: if Bob's `delete index 1` is applied
to Alice's already-updated `"AGO"`, it deletes the `G` instead of the `O`,
producing `"AO"` — a document *neither* user intended.

=== What "correct" means

We need guarantees that can be stated precisely and proven. Three of them:

#defterm([Causality])[
  Event A _causally precedes_ event B if A happened first and could have
  influenced B — for example, B is an edit made by a user who had already seen A
  applied. Two events with no causal order either way are *concurrent*. Alice's
  and Bob's edits above are concurrent: neither saw the other's. Concurrency —
  not time — is what creates conflicts; timestamps cannot detect it, which is why
  Section 1.7 introduces version vectors.
]

#defterm([Convergence])[
  A replica set converges if, once the *same set* of edits has been delivered to
  every replica, every replica holds the *identical* document — regardless of the
  order in which the edits arrived. Convergence is a property of the algorithm,
  not of luck: it must hold for every possible interleaving.
]

#defterm([Intention preservation])[
  The effect of an edit, as observed by its author at the moment they made it,
  must survive concurrency with other edits. Alice meant "`A` before `G`" and Bob
  meant "`O` is gone"; the converged document `"AG"` honors both. An algorithm can
  converge and still be bad (converging to the empty string is trivial), so
  convergence alone is not enough — we want convergence *with* intention
  preservation.
]

There are exactly two families of algorithms in wide production use that deliver
these properties: *Operational Transformation* and *Conflict-free Replicated Data
Types*. A candidate who can define, contrast, and implement one of them owns this
interview.

=== Approach A — Operational Transformation (OT)

#defterm([Operational Transformation (OT)])[
  A concurrency-control technique in which every edit is expressed as an
  *operation* — for plain text, `insert(position, char)` or `delete(position)` —
  and, when two operations are concurrent, one is *transformed* against the other:
  its position is adjusted so that it applies correctly to a document the other
  operation has already modified. OT powers Google Docs. Its lineage: the Jupiter
  system (1995), then Google Wave, then Docs.
]

The transformation rules are a small, complete matrix. To apply operation `a`
after concurrent operation `b` has already been applied, transform `a` against `b`:

#tbl(
  (auto, 1fr),
  header: (hcell[Pair], hcell[Rule for transforming `a` against already-applied `b`]),
  body: (
    [`insert(p_a)` vs `insert(p_b)`], [If `p_b < p_a`, shift `a` right by 1. If `p_b == p_a`, break the tie deterministically (e.g., by client ID) so every replica shifts the same way.],
    [`insert(p_a)` vs `delete(p_b)`], [If `p_b < p_a`, shift `a` left by 1. Otherwise unchanged.],
    [`delete(p_a)` vs `insert(p_b)`], [If `p_b <= p_a`, shift `a` right by 1. Otherwise unchanged.],
    [`delete(p_a)` vs `delete(p_b)`], [If `p_b < p_a`, shift `a` left by 1. If `p_b == p_a`, both deletes target the same character: `a` becomes a no-op.],
  ),
)

The whole of OT is this matrix plus a discipline: *every replica applies the same
operations in the same total order, transforming as needed.* Our running example,
drawn as the classic OT convergence diamond — both paths from the concurrent state
must land on the same document:

#v(0.3em)
#align(center)[
#canvas(h: 5.4cm)[
  #node(6.2cm, 0.15cm, 4.4cm, 0.95cm, [shared state: `"GO"` (rev 41)], fill: faint, edge: slate, size: 8.4pt)
  // left branch
  #node(0.7cm, 2.1cm, 4.2cm, 0.95cm, [Alice sees `"AGO"`], fill: white, edge: primary, size: 8.4pt)
  // right branch
  #node(11.9cm, 2.1cm, 4.2cm, 0.95cm, [Bob sees `"G"`], fill: white, edge: teal, size: 8.4pt)
  // converged
  #node(6.2cm, 4.1cm, 4.4cm, 0.95cm, [both converge to `"AG"`], fill: faint-teal, edge: teal, size: 8.4pt)
  // arrows
  #arrow(7.2cm, 1.12cm, 3.6cm, 2.08cm, color: primary)
  #arrow(9.6cm, 1.12cm, 13.2cm, 2.08cm, color: teal)
  #arrow(3.6cm, 3.07cm, 7.2cm, 4.08cm, color: primary)
  #arrow(13.2cm, 3.07cm, 9.6cm, 4.08cm, color: teal)
  // labels
  #glabel(1.15cm, 1.32cm, [insert `A` at 0], fg: primary)
  #glabel(12.4cm, 1.32cm, [delete index 1], fg: teal.darken(10%))
  #glabel(1.3cm, 3.32cm, [Alice's insert arrives;], fg: slate)
  #glabel(1.3cm, 3.62cm, [transformed: unchanged], fg: slate)
  #glabel(11.55cm, 3.32cm, [Bob's delete arrives;], fg: slate)
  #glabel(11.55cm, 3.62cm, [transformed: delete index 2], fg: slate)
]]
#v(0.1em)

Walking the diamond: on Alice's side, Bob's `delete(1)` is transformed against her
already-applied `insert(0, A)` — since the insert sits at or before the delete
position, the delete shifts right to `delete(2)`, which removes the `O` from
`"AGO"` and yields `"AG"`. On Bob's side, Alice's `insert(0, A)` is transformed
against his already-applied `delete(1)` — the insert position is before the
delete, so it applies unchanged to `"G"`, yielding `"AG"`. Same operations, same
converged document, both intentions preserved.

#notebox([Where the total order comes from])[
  OT requires every replica to transform against the *same* concurrent history.
  The standard way to arrange that is a *single sequencer* per document: the
  server assigns every operation the next integer *revision* (42, 43, 44, …), and
  that assignment _is_ the total order. Clients send operations tagged with the
  revision they were based on; the server transforms them across any operations
  committed in between. We make this precise in the deep dives (Sections 1.9 and
  1.10).
]

=== Approach B — Conflict-free Replicated Data Types (CRDTs)

#defterm([Eventual consistency])[
  A consistency model in which replicas that have stopped receiving new writes
  will *eventually* reach the same state. It promises convergence but says nothing
  about *when*, and nothing about what intermediate states look like.
]

#defterm([Conflict-free Replicated Data Type (CRDT)])[
  A data structure whose concurrent updates are merged by rules that are
  commutative, associative, and idempotent — so replicas that apply the same
  updates in *any* order, even with duplicates, provably converge. This upgraded
  guarantee is called *strong eventual consistency*: convergence as soon as
  updates are delivered, with no central ordering and no transformation step.
]

For text, the canonical CRDT trick is to stop addressing characters by *integer
positions* (which shift under concurrency — the very problem OT transforms away)
and instead give every character a *unique, immutable, orderable identifier*. In
the RGA family of algorithms, an insert is recorded as "insert this new character,
with a fresh globally-unique ID, immediately after character ID X." Concurrent
inserts after the same character interleave deterministically by ID order; deletes
merely mark a character as a tombstone (present in structure, invisible in text).
Because identifiers never shift, no transformation is ever needed — merging is
just set union.

=== Choosing between them

#tbl(
  (auto, auto, auto),
  header: (hcell[Criterion], hcell[OT], hcell[CRDT]),
  body: (
    [Message size], [Tiny: position + char], [Larger: globally-unique IDs per character],
    [Memory / metadata], [None beyond the text], [ID + tombstone per character; tombstone growth needs garbage collection],
    [Needs central sequencer], [Yes (classic form)], [No — tolerates any delivery order],
    [Algorithmic subtlety], [Transformation matrix + history; easy to get subtly wrong], [Merge rules; conceptually cleaner, harder to keep compact],
    [Offline / peer-to-peer], [Awkward (needs the ordering authority)], [Natural fit],
    [Used in production by], [Google Docs, older Etherpad], [Figma (variants), many local-first tools],
  ),
)

*Our decision:* classic OT behind a per-document sequencer — the architecture the
source talk describes, and the one Google Docs runs on. The sequencer is not a
bottleneck (Section 1.5 showed a document peaks at ~150 ops/sec) and it collapses
the hard problem into "transform against a linear log," which we can implement
exactly. We keep version vectors (next section) for reconnect and catch-up.

#tip([Name the trade-off out loud])[
  Saying "I'll use OT because Google Docs does" earns no points. Saying "I'll use
  OT with a per-document sequencer, accepting a single point of ordering per
  document — which I mitigate with failover — in exchange for small messages and a
  linear history that makes version history trivial" is a senior answer. Every
  choice in this chapter is presented as benefit-purchased-at-cost.
]

== Version Vectors: Tracking What Each Replica Has Seen

The OT diamond handles the moment of concurrency. But a real system must also
answer a bookkeeping question constantly: *which operations has this client already
received?* On reconnect, on history fetch, on offline sync, the server and client
must compare "what you have seen" against "what exists." Timestamps cannot express
this (clock skew makes "when" unreliable across machines). We need a *logical*
notion of time.

#defterm([Logical clock / Lamport timestamp])[
  A counter, maintained by each participant, that ticks on every local event and
  is carried with every message; receivers merge it by taking the maximum and
  ticking on. Logical clocks order events by causality rather than by wall-clock
  time, which is exactly what distributed state needs — wall clocks on different
  machines cannot be trusted to agree.
]

#defterm([Version vector])[
  A map from participant ID to a counter: `{Alice: 3, Bob: 1}` means "I have seen
  3 events from Alice and 1 from Bob." Two version vectors compare pointwise:
  - V₁ *dominates* V₂ (V₂ happened-before V₁) if every entry of V₁ is ≥ the
    corresponding entry of V₂, and at least one is strictly greater — V₁ has seen
    everything V₂ has, and more.
  - If neither dominates, the two states are *concurrent* — each has seen
    something the other has not.
  A version vector is a Lamport clock generalized to many writers: it captures
  exactly which causal history a replica has absorbed.
]

In our design the server already assigns a single integer revision per document
(the sequencer), so the *steady-state* sync marker is just `rev = 47`. Version
vectors earn their place at the edges of the design: when a client reconnects
after a network blip during which a *snapshot* was taken, when replicas in
different regions compare state, and in the offline extension. The comparison
logic is the same everywhere: if the server's knowledge dominates the client's,
send exactly the difference.

#pitfall([The snapshot / version-vector trap])[
  The source talk's wry description — a client "never received those writes on
  your local copy since your version vector was more up to date than the document
  snapshot" — points at a real and common bug. Scenario: a snapshot of the
  document is written to one store, but the version metadata recording *which
  revisions the snapshot covers* is written to another, and the two writes are not
  atomic. A reconnecting client compares its version vector against *stale*
  snapshot metadata, concludes it is up to date, and never receives the missing
  operations. The cure is atomicity between a snapshot and its version metadata —
  Section 1.11 shows how, and defines the two-phase commit protocol the talk name-
  drops for exactly this purpose.
]

== API & Protocol Design

The system has two distinct planes, and separating them is itself a design
decision worth naming:

- The *control plane* — create/rename/share/open documents, fetch history. These
  are classic request/response operations; plain HTTPS REST is correct and simple.
- The *data plane* — the live editing session: join, send operations, receive
  operations, presence. This needs a persistent, bidirectional, low-latency
  channel per client.

#defterm([REST])[
  An API style over HTTP in which resources (nouns: `/documents/{id}`) are
  manipulated with a fixed set of methods (verbs: `GET`, `POST`, `PATCH`,
  `DELETE`). Stateless by design: each request carries everything the server
  needs. Ideal for our control plane.
]

#defterm([WebSocket])[
  A protocol (RFC 6455) that upgrades an HTTP connection into a long-lived,
  full-duplex channel: after an initial handshake, *either* side may send a
  message at *any* time, with a few bytes of framing overhead. This is what makes
  sub-150 ms propagation possible — the server can push an edit the instant it is
  committed, with no client polling and no new connection setup.
]

Why not the alternatives?

#tbl(
  (0.85fr, 1.45fr, 1.1fr),
  header: (hcell[Mechanism], hcell[Behavior], hcell[Verdict]),
  body: (
    [Short polling], [Client re-asks "anything new?" every few seconds], [Latency of seconds; wasted requests — rejected],
    [Long polling], [Server holds the request open until data exists], [Near-real-time but a new HTTP request per message burst — heavy at our scale],
    [Server-Sent Events], [Server → client push over HTTP; client sends via separate requests], [Workable, but asymmetric; WebSocket is cleaner for a two-way edit stream],
    [*WebSocket*], [One persistent, bidirectional connection], [*Chosen for the data plane*],
  ),
)

=== Control-plane endpoints

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Method], hcell[Path], hcell[Purpose]),
  body: (
    [`POST`], [`/documents`], [Create a document; returns its `doc_id`],
    [`GET`], [`/documents/{id}`], [Fetch metadata + the latest committed revision number],
    [`PATCH`], [`/documents/{id}`], [Rename, change settings],
    [`DELETE`], [`/documents/{id}`], [Delete (owner only)],
    [`POST`], [`/documents/{id}/share`], [Grant view/edit access to a user or link],
    [`GET`], [`/documents/{id}/history?from=&to=`], [List revisions for the version-history UI],
    [`GET`], [`/documents/{id}/snapshot?rev=`], [Fetch the document as of any revision (view/restore)],
  ),
)

=== Data-plane protocol (WebSocket messages)

After the REST `GET`, the client opens a WebSocket to the gateway and speaks a
small JSON protocol. Every message has a `type`; the important ones:

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Message], hcell[Direction], hcell[Payload & semantics]),
  body: (
    [`join`], [client → server], [`{doc_id, auth_token, last_seen_rev}` — enter the session; `last_seen_rev` enables catch-up],
    [`joined`], [server → client], [`{doc_id, rev, snapshot, collaborators[]}` — current state, possibly after catch-up],
    [`op`], [client → server], [`{doc_id, base_rev, op, client_seq}` — one edit, based on `base_rev`, idempotent via `client_seq`],
    [`ack`], [server → client], [`{client_seq, rev}` — "your edit is committed as revision `rev`"],
    [`op` (broadcast)], [server → client], [`{rev, author, op}` — a committed edit to apply (transform locally if needed)],
    [`presence`], [both], [`{cursor, selection, name}` — ephemeral, never persisted],
    [`sync`], [server → client], [`{rev}` / snapshot — sent when the client is too far behind to patch with ops],
  ),
)

Example committed-operation broadcast:

```json
{
  "type": "op",
  "doc_id": "d_8f31c2",
  "rev": 47,
  "author": "alice@example.com",
  "op": { "kind": "insert", "pos": 0, "ch": "A" }
}
```

Two protocol details deserve emphasis because interviewers probe them. First,
`base_rev` is how the server detects concurrency: if the document is at revision
52 and your operation says `base_rev: 49`, the server transforms it across
revisions 50–52 before committing (Section 1.10). Second, `client_seq` is an
*idempotency key*:

#defterm([Idempotency / idempotency key])[
  An operation is _idempotent_ if performing it twice has the same effect as
  performing it once. Networks retry; clients reconnect and resend. A unique
  client-supplied key per operation (here, `(client_id, client_seq)`) lets the
  server recognize a duplicate delivery and answer with the original result
  instead of applying the edit twice — the difference between at-least-once
  *delivery* and effectively exactly-once *effect*.
]

== Data Model & Storage

Four persistent entities, each with a clear job:

#tbl(
  (0.7fr, 1.6fr, 1.1fr),
  header: (hcell[Entity], hcell[Contents], hcell[Store]),
  body: (
    [`Document`], [`doc_id`, owner, title, ACL, current `rev`], [Metadata DB (relational or document store; sharded by `doc_id`)],
    [`Operation`], [`doc_id`, `rev`, author, transformed op payload, `client_seq`, timestamp], [Operation log — append-only store, ordered by `rev` per document],
    [`Snapshot`], [`doc_id`, `base_rev`, full document text], [Blob/object store; pointer + `base_rev` in metadata DB],
    [`Session`], [who is connected, cursors], [Ephemeral presence cache — *not* persisted],
  ),
)

The two storage ideas that interviewers reward:

#defterm([Operation log (event log)])[
  Storing every change as an immutable, ordered, append-only record instead of
  overwriting state. Current state is always derivable by replaying the log. For
  us the log *is* the product's memory: version history (FR-5) is free, auditing
  is free, and recovery is replay. Append-only logs are also the fastest possible
  write pattern — sequential appends, no random updates.
]

#defterm([Snapshot])[
  A materialized copy of the full document as of a specific revision. Replaying 2
  billion operations to open a document is absurd; instead store a snapshot every
  _N_ operations (say 500) plus the handful of operations since, and reconstruct
  state as `snapshot + tail of the log`. Snapshots are a read optimization over
  the log, never the source of truth — the log is.
]

#notebox([Why a sharded relational/document store + blob store, not one database])[
  The metadata (small, hot, transactional) wants indexes and conditional updates;
  snapshots (large, immutable, cold) want cheap object storage; the operation log
  (append-only, ordered per key) wants a log-structured store. Choosing one engine
  per access pattern — and *saying why* — is the answer this section exists to
  elicit. In an interview, name concrete instincts: PostgreSQL-class for metadata,
  an S3-class blob store for snapshots, a Kafka/Cassandra-class append store for
  the log — while stressing the *properties* matter more than the brands.
]

== High-Level Architecture

The estimation (Section 1.5) gave us the organizing principle: *a thin, stateless,
horizontally scaled connection tier in front of a small, stateful, correctness-
critical core.* Here is the whole system at a glance:

#v(0.3em)
#align(center)[
#canvas(h: 6.1cm)[
  // top row
  #node(0.2cm, 0.1cm, 3.6cm, 1.0cm, [Clients \ web · mobile · desktop], fill: faint, edge: slate)
  #node(5.3cm, 0.1cm, 3.0cm, 1.0cm, [Load balancer / edge], fill: white, edge: slate)
  #node(9.9cm, 0.0cm, 4.6cm, 0.9cm, [REST API service (stateless)], fill: white, edge: primary)
  #node(9.9cm, 1.05cm, 4.6cm, 0.9cm, [WebSocket gateway fleet (stateless)], fill: white, edge: primary)
  // middle
  #node(9.9cm, 2.55cm, 4.6cm, 1.0cm, [Collaboration service \ per-document sequencer], fill: faint-blue, edge: primary)
  // stores
  #node(0.2cm, 4.55cm, 3.9cm, 1.0cm, [Operation log \ append-only], fill: white, edge: teal)
  #node(4.9cm, 4.55cm, 3.9cm, 1.0cm, [Snapshot store \ blobs], fill: white, edge: teal)
  #node(9.6cm, 4.55cm, 3.4cm, 1.0cm, [Metadata DB \ docs · ACLs · rev], fill: white, edge: teal)
  #node(13.4cm, 4.55cm, 3.3cm, 1.0cm, [Presence cache \ ephemeral], fill: white, edge: amber.darken(15%))
  // arrows
  #arrow(3.85cm, 0.6cm, 5.25cm, 0.6cm)
  #arrow(8.35cm, 0.5cm, 9.85cm, 0.45cm)
  #arrow(8.35cm, 0.72cm, 9.85cm, 1.5cm)
  #arrow(11.6cm, 1.98cm, 11.6cm, 2.5cm)
  #arrow(12.9cm, 2.5cm, 12.9cm, 1.98cm, dashed: true)
  #arrow(10.4cm, 3.58cm, 2.7cm, 4.5cm, color: teal)
  #arrow(11.5cm, 3.58cm, 6.9cm, 4.5cm, color: teal)
  #arrow(12.2cm, 3.58cm, 11.6cm, 4.5cm, color: teal)
  #arrow(14.2cm, 1.98cm, 15.0cm, 4.5cm, color: amber.darken(15%), dashed: true)
  // labels
  #glabel(9.2cm, 2.18cm, [ops in], size: 6.9pt)
  #glabel(13.0cm, 2.18cm, [broadcast], size: 6.9pt)
  #glabel(4.4cm, 3.85cm, [append ops (total order)], fg: teal.darken(12%), size: 6.9pt)
  #glabel(8.3cm, 4.0cm, [snapshot every N ops], fg: teal.darken(12%), size: 6.9pt)
  #glabel(12.5cm, 3.95cm, [metadata], fg: teal.darken(12%), size: 6.9pt)
  #glabel(14.85cm, 3.1cm, [cursors], fg: amber.darken(20%), size: 6.9pt)
  #glabel(0.2cm, 5.75cm, [REST tier reads/writes Metadata DB directly; gateway ↔ collaboration routing is per-document (sticky)], size: 7pt)
]]
#v(0.2em)

Component responsibilities, and — more importantly — the reason each exists:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Component], hcell[Responsibility], hcell[Why it is shaped this way]),
  body: (
    [WebSocket gateway], [Hold ~50k client connections each; terminate TLS; forward messages], [Stateless: any client can reconnect to any gateway. Scale by adding boxes — this tier absorbs the 1M-connection problem],
    [Collaboration service], [Owns each active document: sequences ops, transforms, commits, broadcasts], [Stateful but *sharded by document*: a document's whole session lives on one node, so its sequencer is just an in-memory counter. Throughput per doc is tiny (Section 1.5), so one node hosts thousands of docs],
    [Operation log], [Durable, ordered, append-only record per document], [Source of truth; powers history (FR-5), replay, recovery],
    [Snapshot store], [Immutable document snapshots every N ops], [Makes open/reconnect O(1) instead of O(history)],
    [Metadata DB], [Documents, ACLs, current revision counters], [Small, hot, transactional reads/writes],
    [Presence cache], [Live cursors and collaborator lists], [Ephemeral by nature — losing it costs nothing; it rebuilds in seconds],
    [REST API service], [Control plane (Section 1.8)], [Stateless request/response work; ordinary horizontal scaling],
  ),
)

#insight([The one routing rule that makes it all work])[
  *All traffic for a given document flows through the single collaboration node
  that owns it.* Gateways look up `doc_id → owner` (a cheap routing-table read)
  and forward. Because every operation on a document passes through one owner,
  the owner's revision counter is a *total order* — which is exactly what OT needs
  (Section 1.6). Ownership can migrate on failure; the invariant is that there is
  exactly one owner at a time.
]

== Deep Dive: The Edit Pipeline, Step by Step

Follow one keystroke from Alice's keyboard to Bob's screen. The document
`d_8f31c2` is at revision 46; Alice believes it is at revision 42 (she has not yet
received four operations from other editors).

#v(0.3em)
#align(center)[
#canvas(h: 7.0cm)[
  // lifeline headers
  #node(0.1cm, 0.05cm, 2.4cm, 0.62cm, [Alice], fill: faint, edge: slate, size: 8pt)
  #node(4.0cm, 0.05cm, 2.4cm, 0.62cm, [WS gateway], fill: faint, edge: slate, size: 8pt)
  #node(7.9cm, 0.05cm, 2.9cm, 0.62cm, [Collaboration node], fill: faint, edge: slate, size: 8pt)
  #node(12.0cm, 0.05cm, 2.2cm, 0.62cm, [Op log], fill: faint, edge: slate, size: 8pt)
  #node(14.6cm, 0.05cm, 2.1cm, 0.62cm, [Bob], fill: faint, edge: slate, size: 8pt)
  #lifeline(1.3cm, 0.72cm, 6.85cm)
  #lifeline(5.2cm, 0.72cm, 6.85cm)
  #lifeline(9.35cm, 0.72cm, 6.85cm)
  #lifeline(13.1cm, 0.72cm, 6.85cm)
  #lifeline(15.65cm, 0.72cm, 6.85cm)
  // 1
  #arrow(1.3cm, 1.25cm, 5.15cm, 1.25cm, color: primary)
  #glabel(1.5cm, 0.98cm, [1. `op{base_rev: 42, insert(5,'x'), client_seq: 118}`], size: 7pt)
  // 2
  #arrow(5.25cm, 2.15cm, 9.3cm, 2.15cm, color: primary)
  #glabel(5.4cm, 1.88cm, [2. route by `doc_id` to the owning node], size: 7pt)
  // 3 note
  #node(9.7cm, 2.62cm, 5.6cm, 0.85cm, [3. transform vs revs 43–46; assign rev 47], fill: faint-blue, edge: primary, size: 7pt)
  // 4
  #arrow(9.4cm, 3.95cm, 13.05cm, 3.95cm, color: teal)
  #glabel(9.6cm, 3.68cm, [4. append rev 47 (durable write)], size: 7pt)
  // 5
  #arrow(9.3cm, 4.8cm, 5.25cm, 4.8cm, color: slate)
  #glabel(5.5cm, 4.53cm, [5. broadcast committed op], size: 7pt)
  // 6
  #arrow(5.25cm, 5.65cm, 15.6cm, 5.65cm, color: teal)
  #glabel(8.0cm, 5.38cm, [6. `op{rev: 47, …}` → Bob applies it], size: 7pt)
  // 7
  #arrow(5.2cm, 6.5cm, 1.35cm, 6.5cm, color: slate, dashed: true)
  #glabel(1.5cm, 6.23cm, [7. `ack{client_seq: 118 → rev: 47}`], size: 7pt)
]]
#v(0.2em)

In words:

+ *Send.* Alice's keystroke is applied to her local document *immediately* (local
  echo — this is how edit latency stays under 16 ms) and sent as
  `op{base_rev: 42, …}` with her next `client_seq`.
+ *Route.* The gateway does no correctness work; it reads `doc_id`, finds the
  owning collaboration node, forwards.
+ *Sequence & transform.* The owner sees `base_rev: 42` but the document is at 46:
  Alice's operation is *concurrent* with revisions 43–46. It transforms her
  operation against each of them, in order (Section 1.13 implements this loop),
  then stamps it with the next revision, 47.
+ *Commit.* The transformed operation is appended to the operation log. Once the
  append is durable, the edit is *committed* — it can never be reordered or lost.
+ *Broadcast.* The committed operation goes to the gateways of every connected
  editor of the document.
+ *Apply.* Bob's client is not behind (its `base_rev` matches), so it applies the
  operation verbatim. If Bob had a *pending* unacknowledged local edit, he would
  first transform it against this incoming operation — the client runs the same
  transform matrix as the server, keeping his local echo intact.
+ *Acknowledge.* Alice learns her operation is committed as revision 47; her
  pending buffer clears. Her screen never flickered — the local echo and the
  committed result are identical by construction.

#pitfall([Order matters: commit before broadcast])[
  If you broadcast before the log append is durable, a node crash between the two
  steps shows users edits that no longer exist — and on recovery, the "committed"
  history disagrees with what people saw. Durability first, *then* visibility.
  This is the write-path equivalent of "don't acknowledge what you can't
  guarantee."
]

== Deep Dive: Snapshots, Catch-Up & the Two-Phase Lesson

Two housekeeping jobs remain: making *open/reconnect* fast, and keeping a snapshot
and its metadata *atomic*. Both live at the seam between the operation log and the
snapshot store.

=== Catch-up: what to send a rejoining client

When a client sends `join{last_seen_rev}`, the owner compares it to the current
revision `R`:

- *Close behind* (`R - last_seen_rev ≤ 500`): send the missing operations from the
  log. The client transforms any pending local edits across them and is current.
- *Far behind* (offline for hours): replaying thousands of ops is slower than
  sending state. Send `latest snapshot + ops since the snapshot's base_rev`.
- *Offline edits* (the extension): the client presents its *version vector*
  (Section 1.7) instead of a scalar revision; the server computes the set
  difference — ops the client missed — and the client rebases its offline ops on
  top. Vectors, not timestamps, because they compare *causal* histories.

=== The atomicity requirement

A snapshot is useless without its metadata (`base_rev`: which revisions it
covers), and dangerous with *stale* metadata — that is exactly the failure the
source talk jokes about: a client whose version vector is "more up to date than
the document snapshot" concludes it needs nothing and *silently misses writes*.
Two writes must succeed or fail *together*: the snapshot blob, and the
`{snapshot_pointer, base_rev}` record in the metadata DB.

#defterm([Two-phase commit (2PC)])[
  A protocol for committing one atomic operation across *multiple* stores.
  Phase 1 (_prepare_): a coordinator asks every participant "can you commit?"
  Each participant does everything short of committing and votes yes/no.
  Phase 2 (_commit_): if all voted yes, the coordinator tells everyone to commit;
  if any voted no, everyone aborts. 2PC guarantees atomicity but is *blocking*
  (a crashed coordinator can leave participants waiting) and slow (two round
  trips) — so we use the minimal version of the idea, not the maximal one.
]

In practice, prefer the cheapest construction that delivers atomicity:

+ *One store, one transaction.* If the snapshot blob and its metadata live in the
  same database, a single transaction suffices — no 2PC at all.
+ *Immutable blob + conditional pointer update* (our choice). Write the snapshot
  to the blob store under a content-addressed name; only when that write is
  durable, update the metadata row with a conditional compare-and-swap
  (`UPDATE … WHERE base_rev = <old>`). A crash between the steps leaves an
  *orphan blob* — garbage-collectable, never incorrect. Atomicity without a
  coordinator.
+ *Full 2PC* is reserved for when two genuinely independent systems must commit
  together — worth naming in the interview precisely so you can argue you rarely
  need it.

== Deep Dive: Rust Reference Implementation

The concurrency core is small enough to show in full. Three pieces: the wire
protocol types, the OT transform matrix with tests, and the version vector.

=== Protocol types

The data-plane messages from Section 1.8, as Rust types (serde for JSON):

```rust
use serde::{Deserialize, Serialize};

/// One edit to a plain-text document.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum Op {
    Insert { pos: usize, ch: char },
    Delete { pos: usize },
}

/// Data-plane messages (client ⇄ server), serialized as JSON.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Msg {
    Join    { doc_id: String, auth: String, last_seen_rev: u64 },
    Joined  { doc_id: String, rev: u64, snapshot: String },
    Op      { doc_id: String, base_rev: u64, client_seq: u64, op: Op },
    Ack     { client_seq: u64, rev: u64 },
    /// Server → clients: a committed operation.
    Bcast   { doc_id: String, rev: u64, author: String, op: Op },
}
```

The `#[serde(tag = "type")]` attribute makes the JSON look exactly like the
protocol table: a `type` field distinguishes the variants.

=== The OT transform matrix

This is Section 1.6's table, made executable. `transform(a, b, a_wins_ties)`
returns the operation `a` adjusted to apply *after* the concurrent operation `b`
has been applied:

```rust
use crate::Op;

/// Transform `a` so it applies correctly *after* concurrent op `b`.
/// `a_wins_ties` breaks same-position insert/insert ties identically
/// on every replica (e.g., by client id) — determinism is what matters.
pub fn transform(a: &Op, b: &Op, a_wins_ties: bool) -> Option<Op> {
    match (a, b) {
        (Op::Insert { pos: pa, ch: ca }, Op::Insert { pos: pb, .. }) => {
            let shifted = if *pa > *pb || (*pa == *pb && !a_wins_ties) { pa + 1 } else { *pa };
            Some(Op::Insert { pos: shifted, ch: *ca })
        }
        (Op::Insert { pos: pa, ch: ca }, Op::Delete { pos: pb }) => {
            let shifted = if *pa > *pb { pa - 1 } else { *pa };
            Some(Op::Insert { pos: shifted, ch: *ca })
        }
        (Op::Delete { pos: pa }, Op::Insert { pos: pb, .. }) => {
            let shifted = if *pa >= *pb { pa + 1 } else { *pa };
            Some(Op::Delete { pos: shifted })
        }
        (Op::Delete { pos: pa }, Op::Delete { pos: pb }) => {
            if pa == pb { None }                       // both deleted the same char
            else { Some(Op::Delete { pos: if *pa > *pb { pa - 1 } else { *pa } }) }
        }
    }
}

/// Apply an operation to a document buffer.
pub fn apply(doc: &mut String, op: &Op) {
    match op {
        Op::Insert { pos, ch } => {
            let byte = doc.char_indices().nth(*pos).map_or(doc.len(), |(i, _)| i);
            doc.insert(byte, *ch);
        }
        Op::Delete { pos } => {
            if let Some((byte, c)) = doc.char_indices().nth(*pos) {
                doc.drain(byte..byte + c.len_utf8());
            }
        }
    }
}
```

Note the discipline the code makes explicit: character positions, not byte
offsets (Rust strings are UTF-8; mixing the two is a classic production bug), and
`None` for the delete/delete collision — an operation transformed into a no-op.

The convergence diamond from Section 1.6, as a test:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn go_diamond_converges() {
        let alice_op = Op::Insert { pos: 0, ch: 'A' };  // "GO" -> "AGO"
        let bob_op   = Op::Delete { pos: 1 };           // "GO" -> "G"

        // Alice's side: apply hers, transform Bob's against it, apply.
        let mut a_doc = String::from("GO");
        apply(&mut a_doc, &alice_op);
        let bob_at_alice = transform(&bob_op, &alice_op, false).unwrap();
        apply(&mut a_doc, &bob_at_alice);

        // Bob's side: apply his, transform Alice's against it, apply.
        let mut b_doc = String::from("GO");
        apply(&mut b_doc, &bob_op);
        let alice_at_bob = transform(&alice_op, &bob_op, true).unwrap();
        apply(&mut b_doc, &alice_at_bob);

        assert_eq!(a_doc, b_doc);          // convergence
        assert_eq!(a_doc, "AG");           // intention preservation
    }
}
```

=== The server-side session: transforming against history

The owner node keeps a per-document session. When an operation arrives based on
an old revision, transform it across everything committed since (step 3 of the
pipeline):

```rust
pub struct DocSession {
    pub rev: u64,
    pub doc: String,
    pub log: Vec<(u64, Op)>,        // (revision, committed op); the op log in memory
    pub since_snapshot: usize,      // ops committed since last snapshot
}

impl DocSession {
    pub fn commit(&mut self, base_rev: u64, mut op: Op) -> Result<u64, &'static str> {
        if base_rev > self.rev { return Err("base_rev from the future"); }
        // Transform across every revision the client had not seen.
        for (_, past) in self.log.iter().skip(base_rev as usize) {
            op = transform(&op, past, false).ok_or("op became a no-op")?;
        }
        self.rev += 1;
        apply(&mut self.doc, &op);
        self.log.push((self.rev, op.clone()));
        self.since_snapshot += 1;
        if self.since_snapshot >= 500 { self.snapshot(); }   // Section 1.9 policy
        Ok(self.rev)                                          // -> ack + broadcast
    }

    fn snapshot(&mut self) { /* write blob, then conditional pointer update */ 
        self.since_snapshot = 0;
    }
}
```

This is deliberately unglamorous — a counter and a loop. That is the payoff of
the architecture: because *all* operations for a document funnel through one
owner, the "distributed consensus" needed here is no consensus at all.

=== Version vector

Section 1.7's definition, implemented with its three-way comparison:

```rust
use std::collections::HashMap;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VersionVector(pub HashMap<String, u64>);

#[derive(Debug, PartialEq, Eq)]
pub enum Ordering { Before, After, Equal, Concurrent }

impl VersionVector {
    pub fn tick(&mut self, who: &str) { *self.0.entry(who.into()).or_insert(0) += 1; }

    /// Pointwise comparison: Before = self is causally dominated by other.
    pub fn compare(&self, other: &Self) -> Ordering {
        let mut less = false;
        let mut greater = false;
        for id in self.0.keys().chain(other.0.keys()) {
            let a = self.0.get(id).copied().unwrap_or(0);
            let b = other.0.get(id).copied().unwrap_or(0);
            less |= a < b;
            greater |= a > b;
        }
        match (less, greater) {
            (false, false) => Ordering::Equal,
            (true, false)  => Ordering::Before,
            (false, true)  => Ordering::After,
            (true, true)   => Ordering::Concurrent,
        }
    }

    /// Element-wise maximum: the merged causal history of two replicas.
    pub fn merge(&mut self, other: &Self) {
        for (id, &n) in &other.0 {
            let e = self.0.entry(id.clone()).or_insert(0);
            *e = (*e).max(n);
        }
    }
}
```

The catch-up decision from Section 1.12 is now three lines: if the client's vector
is `Before` the server's, send the ops it lacks; if `Equal`, send nothing (and —
per the pitfall — verify the *snapshot metadata* said the same thing); if
`Concurrent`, the client has offline edits: send the diff and rebase.

== Deep Dive: Presence & Live Cursors

Presence — "who is here, and where is their cursor" — looks trivial and hides one
elegant detail: *cursor positions are text positions*, so they must be transformed
by the same OT matrix as edits. If Alice's cursor sits at position 10 and Bob
inserts three characters at position 4, Alice's cursor must render at 13. Clients
transform remote cursors against every incoming operation; the server simply
relays.

Design rules that keep presence cheap:

- *Never persist it.* Presence flows through the ephemeral presence cache and
  broadcasts; a client heartbeat every few seconds refreshes it. If presence data
  is lost, it rebuilds within one heartbeat — this is why the architecture draws
  it as a dashed, separate path.
- *Don't sequence it.* Presence messages carry no `rev` and bypass the operation
  log entirely; a stale cursor for 100 ms is invisible to users, while a stale
  *edit* is a correctness bug.
- *Throttle it.* Cursor moves fire dozens of events per second per editor; cap
  updates (e.g., 10/sec/client) — 50 editors × 10 updates = 500 tiny messages/sec,
  which the same per-document owner trivially fans out.

== Scaling & Sharding

#defterm([Sharding (horizontal partitioning)])[
  Splitting data or work across many machines by a key, so that each machine owns
  a disjoint slice. Sharding is the fundamental answer to "one machine is not
  enough": pick the right key and load grows by adding machines rather than by
  growing them.
]

Every tier shards by its natural key:

- *Gateways*: stateless, so any consistent routing works; connections balance
  across the fleet, and reconnects land anywhere.
- *Collaboration nodes*: sharded *by document*. A routing service maps `doc_id →
  owner` with a lease (a time-limited ownership grant the node must renew; on
  crash the lease expires and ownership moves — this is how we keep "exactly one
  sequencer per document" without human intervention).
- *Operation log / snapshots / metadata*: sharded by `doc_id` as well, so all of a
  document's data is local to its shard.

#insight([The 50-editor cap is a load-shedding decision])[
  Why can a document never become a "hot shard" that melts its owner? Because we
  capped concurrency at 50 editors — a product decision with an architectural
  dividend. A live-blog with a million *writers* would need a different design
  (tree of sequencers, or CRDTs with no central order). Naming which NFR protects
  you from which failure mode is exactly the reasoning interviewers listen for.
]

== Failure Modes & Recovery

A senior answer enumerates what breaks *before* being asked. The playbook:

#tbl(
  (auto, 1fr),
  header: (hcell[Failure], hcell[Handling]),
  body: (
    [Client disconnects], [Its edits are already durable in the log (commit-before-broadcast). On reconnect: `join` with `last_seen_rev`, catch up per Section 1.12. Presence entry expires on its own.],
    [WebSocket gateway dies], [Clients reconnect to any other gateway (they are stateless). In-flight unacked ops are resent and deduplicated by `client_seq` (idempotency).],
    [Collaboration node dies], [Lease expires; routing service assigns a new owner, which rebuilds the session state as `latest snapshot + log tail` and resumes sequencing. Clients see a reconnect, not data loss.],
    [Duplicate message delivery], [Impossible to prevent on real networks — so we make it harmless: `client_seq` idempotency on the write path, revision numbers on the read path (already have rev 47? ignore the re-broadcast).],
    [Op-log replica loss], [The log is replicated (3× is standard); a lost replica is replaced from its peers.],
    [Network partition], [A client that cannot reach the server keeps editing locally and rebases on reconnect (version-vector diff, Section 1.12) — or shows "offline, changes will sync" if we choose availability over freshness. A partitioned *server-side* minority refuses ownership transfers: correctness beats liveness there.],
  ),
)

== Trade-offs & Alternatives

The design is a bundle of purchased benefits and accepted costs. Saying the costs
out loud is what distinguishes a design from a wish list:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Benefit purchased], hcell[Cost accepted]),
  body: (
    [Per-document sequencer + OT], [Small messages, total order, free version history, simple reasoning], [Single point of *ordering* per doc (mitigated by lease failover, seconds of unavailability on crash); OT matrix must be exactly right],
    [CRDT instead], [No sequencer; offline and peer-to-peer for free], [Per-character IDs and tombstones; heavier storage and GC; harder to bolt on a clean linear history],
    [WebSocket data plane], [Sub-150 ms push; bidirectional], [1M long-lived connections to manage; load balancers must tolerate them],
    [Op log as source of truth], [History, audit, replay, recovery all free], [Storage growth (~550 GB/day at our scale) and the snapshot machinery to keep reads fast],
    [Single-region write ownership per doc], [No cross-region consensus on the hot path], [Editors far from the owner's region see higher propagation latency],
  ),
)

#notebox([PACELC, briefly])[
  A refinement of the CAP theorem: *if* there is a Partition, choose Availability
  or Consistency; *else* (normal operation), choose Latency or Consistency. Our
  design picks *consistency* on both branches for the edit path (single owner,
  total order) and *availability/latency* for presence (ephemeral, best-effort) —
  different subsystems may legitimately make different PACELC choices.
]

== Observability & SLOs

#defterm([SLI / SLO])[
  A _Service Level Indicator_ is a measurable quantity (e.g., propagation latency
  at p95). A _Service Level Objective_ is its target ("p95 < 400 ms"). SLOs turn
  "the system feels slow" into an engineering signal with an error budget.
]

What we instrument, at minimum: per-document ops/sec and transform rates; end-to-
end propagation latency (client-side measured, tagged by region); ack latency;
WebSocket connections and message rates per gateway; catch-up size distribution
(reconnect storms reveal themselves here); snapshot lag (`current_rev -
snapshot.base_rev`); lease-failover count. Alerts fire on SLO burn, not on
individual machine failures — the failure table above exists precisely so that
single failures are non-events.

== Interview Wrap-Up

*Likely follow-ups, with one-line answers:*

- _"Rich text?"_ — Operations gain attributes (bold ranges, styles); the transform
  matrix grows cases, the architecture does not change.
- _"Comments / suggestions?"_ — Anchored to character ranges that transform like
  cursors; stored in metadata DB, off the hot path.
- _"End-to-end encryption?"_ — Server cannot read content, so server-side OT is
  impossible; this pushes you toward client-side CRDTs. A great example of a
  requirement that *re-architects* the core.
- _"5,000 simultaneous editors?"_ — Our 50-editor cap is what licenses the single
  sequencer; beyond it, shard the document itself or move to CRDTs.
- _"Undo?"_ — Per-user inverse operations transformed through the log — easy to
  describe, subtly hard to make intuitive; mention it, don't build it live.

*If you remember five things:*

+ The product is a distributed-state synchronizer wearing a text editor's clothes.
+ Convergence + intention preservation are the correctness bar; LWW and locks both
  fail it.
+ A per-document total order (sequencer) reduces "distributed consensus" to a
  counter and a transform loop.
+ Commit durably, then broadcast — never show a user an edit you cannot guarantee.
+ Snapshots and their version metadata commit atomically, or clients silently miss
  writes (Section 1.12).

== Summary & Further Reading

We designed a real-time collaborative plain-text editor for 10M DAU: a stateless
WebSocket gateway tier holding a million connections; a collaboration service that
owns each document and imposes a total order on its operations; operational
transformation to merge concurrent edits; an append-only operation log as the
source of truth with periodic snapshots; version vectors for catch-up and offline
diffing; and idempotent protocols that survive the network's misbehavior.

*Primary source for this chapter:*
- #link("https://www.youtube.com/watch?v=YCjVIDv0zQY")[*“12: Design Google Docs/Real Time Text Editor”* — Systems Design Interview Questions With Ex-Google SWE (Jordan has no life)] — the mock-interview walkthrough this chapter expands.

*Foundations worth reading:*
- Ellis & Gibbs, _Concurrency Control in Groupware Systems_ (1989) — the original OT paper.
- Nichols et al., _Jupiter: high-latency collaboration_ (1995) — OT with a central server, the direct ancestor of our design.
- Shapiro et al., _Conflict-free Replicated Data Types_ (2011) — the CRDT formulation.
- Google Wave's OT whitepapers, and Figma's engineering blog on multiplayer — production war stories for both families.

== Chapter 1 Glossary

A one-glance index of every term this chapter defined. Later chapters assume it.

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning in one line]),
  body: (
    [System design interview], [Open-ended architecture design under a 45–60 minute clock],
    [HLD / LLD], [Whole-system architecture / internal mechanics of the hard components],
    [Functional requirement], [What the system must do],
    [Non-functional requirement], [How well it must do it: scale, latency, availability, consistency],
    [DAU / QPS], [Daily active users / queries per second],
    [Back-of-the-envelope estimation], [Approximate arithmetic that sizes the problem before designing],
    [Latency], [Cause → observable effect; here: local echo < 16 ms, propagation < 150 ms],
    [Availability], [Fraction of time the system serves requests],
    [Mutual exclusion (lock)], [One writer at a time — correct, but kills real-time collaboration],
    [Last-writer-wins], [Latest timestamp overwrites — simple, but silently loses edits],
    [Causality / concurrency], ["Could A have influenced B?" If neither way: concurrent],
    [Convergence], [Same delivered edits ⇒ identical document on every replica],
    [Intention preservation], [Each author's observed edit effect survives concurrency],
    [Operational Transformation], [Adjust concurrent operations' positions so all replicas converge],
    [CRDT], [Data type whose merge rules converge without a central order],
    [(Strong) eventual consistency], [Replicas converge (immediately upon delivery, for SEC)],
    [Logical clock / Lamport], [Causality-tracking counters instead of wall-clock time],
    [Version vector], [Per-participant counters recording exactly what a replica has seen],
    [REST], [Stateless resource-oriented HTTPS API — our control plane],
    [WebSocket], [Persistent full-duplex client↔server channel — our data plane],
    [Idempotency key], [Client-supplied unique key making retried operations safe],
    [Operation log], [Immutable append-only record of all edits; the source of truth],
    [Snapshot], [Materialized document at a revision; read optimization over the log],
    [Two-phase commit], [Prepare-then-commit protocol for atomic writes across stores],
    [Sharding], [Partitioning work/data by key across machines — here, by document],
    [Presence], [Ephemeral who's-here-and-where state; never persisted],
    [SLI / SLO], [A measured indicator / its target, defining "healthy"],
  ),
)
