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
  concurrency machinery. This chapter follows the same arc, but slows every step
  down: full definitions before first use, capacity mathematics with every
  assumption stated, protocol specifications, and Rust reference implementations
  you could compile tomorrow.
]

#v(0.4em)

== The Problem Statement

Picture the scene. The interviewer finishes small talk, leans back, and says:

#block(inset: (left: 14pt), stroke: (left: 2pt + primary), above: 0.9em, below: 0.9em)[
  #text(style: "italic", size: 10.5pt)[
    "Design a real-time collaborative text editor — something like Google Docs.
    Multiple people should be able to edit the same document at the same time
    and see each other's changes as they happen."
  ]
]

If you have never thought about this problem before, your first instinct might be
that it is a CRUD application with a chatty front end: store documents, let people
edit them, save often. That instinct survives for about thirty seconds — right up
to the moment you ask yourself the question the whole chapter hangs on: _when two
people type at the same time, in different places, on different continents, what
is the document now?_ There is no obviously correct answer, and several plausible
answers are wrong in ways that lose user data. Underneath its ordinary surface,
this prompt is a distributed-state synchronization problem — one of the richest in
the entire interview canon.

Notice what the prompt does *not* tell you. How many users? How many editors per
document? Plain text or rich text? What happens when someone loses connectivity?
Is there version history? Every one of those omissions is deliberate: the
interviewer is watching to see whether you discover the ambiguity and close it, or
whether you charge ahead and design whatever product happens to live in your head.
Closing those gaps — politely, out loud, and with reasons — is most of your grade.

#defterm([High-level design (HLD) / low-level design (LLD)])[
  _HLD_ is the architecture of the whole system: which services exist, which data
  stores they use, which network paths connect them, and — most importantly —
  _why_ each piece earned its place. _LLD_ is the internal mechanics of the one or
  two components where the real difficulty lives: the data structures, the
  algorithms, the exact protocols. A strong interview performance does HLD first,
  in breadth, and then drills into LLD where the problem is genuinely hard. In
  this problem the hard component is the concurrency-control core — the machinery
  that decides what the document _is_ when edits collide — so that is where we
  will spend our LLD budget.
]

Here is the roadmap we will follow together. First we negotiate scope, because
designing the wrong product elegantly is still designing the wrong product. Then
we pin down functional and non-functional requirements, and do the arithmetic that
tells us where the scale actually lives. Only then do we open the core challenge —
concurrent editing — and give it the several sections it deserves, ending in
working Rust. Architecture, protocols, storage, failure handling, and trade-offs
follow from that core, not the other way around. That order is itself a lesson:
in this problem, correctness considerations drive the architecture, so we let
them.

== Scope & Clarifying Questions

There is a saying worth internalizing before any interview: _never design the
prompt you were handed; design the prompt you negotiated._ The series this chapter
draws on runs its interviews as a dialogue, and that is exactly how a real
interview should feel to you — not an interrogation, but two engineers scoping a
project together. Watch how a strong opening exchange goes, and pay attention not
just to the questions but to what each one *buys*:

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

Let us walk through why these particular six questions, because the selection is
not arbitrary — each one collapses a different axis of the design space.

The _plain text versus rich text_ question decides how we model a document. Plain
text lets us say "a document is an ordered sequence of characters," which means an
edit can be described by a position and a character — a tiny, clean model. Rich
text would force us to carry formatting ranges, embedded objects, and nested
structure through every algorithm we build; the concurrency math stays
conceptually identical but the bookkeeping triples. Getting plain text granted is
the single biggest simplification available in this interview, so ask for it
first.

The _editors-per-document_ question is quietly the most important number in the
chapter. Fifty concurrent editors means one document's write traffic is trivial —
a few hundred operations per second in a typing frenzy — which means a *single
server* can own a whole document and serialize its edits. Had the answer been
"fifty thousand," every design decision that follows would invert. Always ask for
the per-entity number, not just the global one.

The _total scale_ question (10M daily users, documents up to a few hundred
kilobytes) feeds the capacity estimation in Section 1.5. The _presence_ question
adds a real-time broadcast feature with a very different tolerance profile from
edits — we will exploit that difference later. The _offline_ question probes the
deepest axis of all: a system that must merge hours of disconnected work needs a
different concurrency mechanism at its heart, so getting "assume connected" is a
license for the mainstream design. And the _version history_ question commits us
to storing not just the document but its entire evolution — which, as you will
see, turns out to be nearly free once we choose the right storage model.

From this exchange we can freeze the scope. Everything later in the chapter traces
back to these decisions, so state them explicitly — literally summarize them back,
as the box below does — and get a nod from the interviewer before moving on.

#block(fill: faint-blue, radius: 6pt, inset: (x: 14pt, y: 10pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: primary, tracking: 0.1em)[AGREED SCOPE]
  #v(4pt)
  Plain-text documents up to ~500 KB; up to *50 concurrent editors per document*;
  *10M daily active users*; live cursors and presence; full version history;
  connected editing for the core design (offline sketched as an extension).
]

#tip([Negotiate scope in both directions])[
  Candidates usually think clarifying questions only *shrink* scope. Used well,
  they also *expand* it — deliberately. Asking "do we need presence?" signals that
  you know the feature exists, that it costs something, and that you can build it
  if wanted. Offer features and let the interviewer decline them; you get credit
  for knowing the product space, and you protect yourself from discovering a
  hidden requirement at minute forty.
]

== Functional Requirements

Before listing what our system must do, let us be precise about what kind of
statement a functional requirement even is — interviews are quietly lost by people
who mix the two requirement families and end up with a muddled design.

#defterm([Functional requirement (FR)])[
  A statement of what the system must *do* — an observable behavior a user can, in
  principle, verify: "a user can create a document," "a user sees another user's
  cursor." Functional requirements define the feature set. Crucially, they say
  nothing about how fast, how available, or how consistent the system must be —
  those qualities are _non-functional requirements_, which we define next, and
  which are where the architecture actually comes from.
]

Here are our functional requirements, scoped by the negotiation above. As you read
each one, notice that it is testable — you could write an end-to-end test for it
without knowing anything about the implementation:

+ *FR-1 — Document management.* Users can create, rename, open, and delete
  documents. This is ordinary CRUD, and we say so out loud: it tells the
  interviewer we know which parts of the system are boring and which are not.
+ *FR-2 — Real-time collaborative editing.* Multiple users can edit one document
  concurrently, and every connected editor sees every other editor's changes
  within a fraction of a second. This is the requirement the whole chapter serves.
+ *FR-3 — Presence.* Each editor sees who else is in the document, with a live
  cursor (and selection) per collaborator, labeled with their name. Presence is
  real-time like FR-2, but unlike FR-2 it tolerates loss and delay — remember that
  asymmetry; we will design for it explicitly.
+ *FR-4 — Persistence.* A document is never lost because a client disconnects;
  reopening it later yields its latest committed state. Combined with FR-2, this
  means every edit must be made durable *while* the real-time dance continues.
+ *FR-5 — Version history.* Users can browse the full history of a document and
  view or restore any earlier revision. This requirement will end up shaping our
  storage model more than any other.
+ *FR-6 — Sharing & access control.* A document has an owner; the owner grants
  view or edit access to others via a shareable link or explicit invite.

And just as important, say what we are *not* building: rich text, comments and
suggestions, end-to-end encryption, and offline-first editing as a core flow.
Naming exclusions does two things for you: it protects your fifty minutes, and it
demonstrates that you know where the boundary of a problem lies — a senior habit.

== Non-Functional Requirements

#defterm([Non-functional requirement (NFR)])[
  A statement of how *well* the system must perform its functions: scale, latency,
  availability, durability, consistency. NFRs are where design decisions actually
  come from, and this is worth pausing on: two systems with identical functional
  requirements — say, a chat app and a payment ledger, both of which "store and
  deliver messages" — can have opposite architectures purely because their NFRs
  differ. When you state an NFR in an interview, you are really stating which
  trade-offs you are about to make.
]

Three qualities dominate this particular problem, and each deserves a precise
definition before we use it as a design tool:

#defterm([Latency])[
  The time between a cause and its observable effect. Two distinct latencies
  matter here, and keeping them separate is essential. _Edit latency_ is the time
  from your keystroke to that character appearing in *your own* document — it must
  feel instant, which in practice means under ~16 ms (one display frame), which in
  turn means it must be applied locally, with no network round trip in the way.
  _Propagation latency_ is the time from your keystroke to its appearance on a
  *collaborator's* screen — our target is under ~150 ms within a region, fast
  enough that collaboration feels live rather than turn-based.
]

#defterm([Availability])[
  The fraction of time the system is able to serve requests, usually quoted in
  "nines." Editing must remain available even when individual servers fail —
  which, at our scale, they do constantly — so no single machine may be
  indispensable to the system as a whole. We will aim for the classic "three
  nines" (99.9%, about 8.8 hours of downtime per year) for the editing path, and
  we will see exactly which component that constrains.
]

#defterm([Consistency / convergence])[
  In a system where many actors mutate shared state concurrently, _consistency_
  describes what guarantees observers get about the states they see. For a
  collaborative editor, the guarantee that matters is *convergence*: once the same
  set of edits has been delivered to every replica, every replica must hold the
  *identical document*. If two users could permanently end up looking at different
  text, the product is broken no matter how fast or how available it is. How
  convergence is achieved — crucially, *without* locking the document — is the
  core challenge of this chapter and gets its own section (Section 1.6).
]

The remaining NFRs, stated as concrete targets we can design against:

#tbl(
  (auto, 1fr),
  header: (hcell[Quality], hcell[Target]),
  body: (
    [*Propagation latency*], [p50 \< 150 ms within a region; p95 \< 400 ms cross-region],
    [*Edit (local echo) latency*], [\< 16 ms — edits apply locally, synchronously, before any server contact],
    [*Editors per document*], [Up to 50 concurrent, with no degradation],
    [*System scale*], [10M DAU; ~1M simultaneous connections at peak],
    [*Durability*], [No committed edit is ever lost — history is the product's memory],
    [*Availability*], [99.9% for editing; reading a document should survive almost anything],
  ),
)

#insight([Consistency is the NFR that shapes this design])[
  Most interview problems are dominated by throughput (design Twitter) or storage
  (design Dropbox). This one is dominated by *correctness under concurrency*. The
  moment two users type at the same time, you owe the world a mathematical answer
  to "what is the document now?" — and that answer, not any load number, is what
  decides the architecture. Section 1.6 is where this interview is won or lost;
  everything else is infrastructure in service of it.
]

== Back-of-the-Envelope Estimation

Before drawing a single box, we count. This surprises many candidates the first
time — surely architecture comes before arithmetic? — but the arithmetic *decides*
the architecture, so it must come first.

#defterm([Back-of-the-envelope estimation])[
  Rapid, approximate arithmetic — round numbers, stated assumptions — that sizes a
  system *before* you design it. Precision is not the goal; nobody cares whether
  you write 220 GB or 550 GB. The goal is to discover *which constraints bite*: a
  design for 500 messages per second and a design for 500,000 messages per second
  are different systems, and you cannot know which one you owe the interviewer
  until you count.
]

#defterm([DAU / QPS])[
  _DAU_ (daily active users) counts the distinct users active in a day — a
  business number. _QPS_ (queries per second) is the request rate a system
  actually handles — an engineering number. Interview estimates are mostly the art
  of converting the first into the second via an activity model: "each user does
  X, about Y times a day, so the average rate is Z, and peak is some multiple of
  average."
]

*Assumptions.* Say them out loud, write them on the board, and explicitly invite
correction — "does that sound right to you?" is a collaboration signal, not a
weakness:

- 10M DAU; each user actively edits on ~3 documents per day, in sessions of
  ~20 minutes.
- At peak, ~5% of DAU are simultaneously connected: *500k concurrent connections*.
  We will design for 1M, because capacity you do not need is cheaper than capacity
  you do not have.
- An active typist produces ~3 keystroke-operations per second in bursts, but
  averaged over a whole session — reading, thinking, chatting, coffee — about 0.5
  ops/sec per connected user.
- One operation (a character insert or delete plus its metadata) is about 250
  bytes on the wire.
- Average document size is ~20 KB of text; 500 KB worst case per our scope.

*Derived numbers* — each line follows mechanically from the assumptions:

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
    [Connections per WebSocket gateway], [~50k], [commodity servers hold tens of thousands of mostly-idle connections],
    [Gateways needed], [~20–40], [1M conns ÷ 25–50k each, plus redundancy],
  ),
)

Now — and this is the part that actually earns the points — read the table back
and ask what it is *telling* you.

#insight([What the math tells us])[
  Two facts jump out of these numbers, and between them they dictate the whole
  architecture. First: the system-wide write rate, hundreds of thousands of
  operations per second, sounds intimidating — but it is *perfectly sharded by
  document*. No document ever sees more than its 50 editors, producing maybe 150
  ops/sec in a frantic burst. That is trivial load for a single thread, which
  means the correctness-critical logic can live on one node per document with
  room to spare. Second: the place where scale genuinely lives is the connection
  tier — a million mostly-idle WebSocket connections is a pure capacity problem,
  solved by piling up commodity boxes. So the conclusion writes itself: put the
  hard, stateful correctness logic *per document* (where throughput is tiny), and
  make the connection tier *stateless and horizontal* (where throughput is huge).
  Hold that thought; Section 1.10 turns it into boxes and arrows.
]

== The Core Challenge: Concurrent Editing

Everything else in this chapter — gateways, storage, protocols — is standard
distributed-systems plumbing that you will reuse in a dozen other designs. This
section is the intellectual center of the problem, and of the source talk, and we
will take it slowly: first we watch the naive approaches fail, then we define
precisely what "correct" even means, and only then do we meet the two algorithm
families that achieve it.

=== Why naive approaches fail

To see the difficulty, you need exactly two users and two characters. Suppose
Alice and Bob are editing the document `"GO"` — `G` at index 0, `O` at index 1 —
and they type *at the same time*, each seeing only the original:

- *Alice* inserts the character `A` at index 0; she is turning `"GO"` into
  `"AGO"`.
- *Bob* deletes the character at index 1; he is turning `"GO"` into `"G"`.

What should the document be once both edits have been delivered everywhere?
Neither user did anything wrong, and their intentions do not conflict in spirit:
the only defensible answer is `"AG"` — Alice's `A` before the `G`, and the `O`
gone. Hold that answer in mind, and now watch two strategies you might reach for
first both fail to produce it.

*Naive strategy 1 — lock the document.* Only one editor may type at a time;
everyone else waits for the lock. Is it correct? Absolutely — mutual exclusion
serializes everything, so no conflict can ever occur. Is it acceptable? Never:
you have designed Google Docs with a "please wait your turn" dialog. Real-time
collaboration is precisely the absence of global mutual exclusion, so this
"correct" answer fails the product.

#defterm([Mutual exclusion / locking])[
  A concurrency-control technique in which a resource may be modified by only one
  actor at a time; everyone else blocks until the lock is released. Locks are the
  oldest correct answer to shared state, and they work by *serializing* — trading
  parallelism for safety. That trade is often right (database internals are full
  of locks, as Chapter 11 will show), but it is fatal when the resource is a
  shared document with fifty simultaneous editors and the whole point is that
  nobody ever waits.
]

*Naive strategy 2 — last-writer-wins.* Attach a timestamp to each edit, and when
edits collide, keep the latest and discard the rest. This is a real, widely used
strategy — just not here.

#defterm([Last-writer-wins (LWW)])[
  A conflict-resolution rule: when two writes to the same datum race, keep the one
  with the later timestamp and drop the other. It is simple, fast, and *loses data
  by design* — one of the two writes silently vanishes. LWW is a fine choice for
  values that are legitimately overwritten as wholes (your profile picture, a
  "currently online" flag), and a terrible choice for anything that should be
  *merged*, like text.
]

Apply LWW to our example and the failure is concrete: if Bob's delete "wins,"
Alice's `A` disappears from the document she watched herself type. If Alice's
insert "wins," Bob's delete is lost and the `O` he deleted resurrects. Either way,
one user's clear intention is silently destroyed, and the product is
untrustworthy.

There is a third failure mode worth seeing, because it is subtler and it is the
one that motivates the real solution. Suppose you skip conflict resolution
entirely and just *apply* each edit at the position it names. Alice's
`insert(0, 'A')` reaches Bob and works fine. But Bob's `delete(1)` reaches Alice's
machine *after* her insert, so her document is already `"AGO"` — and deleting the
character at index 1 removes the `G` instead of the `O`, producing `"AO"`, a
document *neither* user intended. The positions themselves shifted under
concurrency. Remember that observation; the fix is built on it.

=== What "correct" means

If the naive approaches fail, what would a correct approach have to guarantee?
Three properties, each of which we can state precisely — and once stated
precisely, they become testable.

#defterm([Causality])[
  Event A _causally precedes_ event B if A happened first *and could have
  influenced* B — for instance, B is an edit made by a user who had already seen A
  applied to their screen. Two events with no causal order in either direction are
  *concurrent*. Alice's and Bob's edits above are concurrent: neither had seen the
  other's. The deep point is that concurrency — not time — is what creates
  conflicts, and wall-clock timestamps cannot detect concurrency (two machines'
  clocks never agree well enough). That is why Section 1.7 introduces version
  vectors, which track causality directly.
]

#defterm([Convergence])[
  A set of replicas converges if, once the *same set* of edits has been delivered
  to all of them, every replica holds the *identical* document — regardless of the
  order in which the edits arrived. Note that convergence is a property of the
  *algorithm*, not of luck or timing: it must hold for every possible
  interleaving, including the ugly ones that only happen at 3 a.m. during a deploy.
]

#defterm([Intention preservation])[
  The effect of an edit, as observed by its author at the moment they made it,
  must survive concurrency with other edits. Alice meant "`A` before `G`"; Bob
  meant "`O` is gone"; the converged document `"AG"` honors both. This property is
  what rules out degenerate "solutions": an algorithm could converge trivially by
  always producing the empty string — every replica agrees! — and be worthless. So
  we want convergence *with* intention preservation, and any algorithm we accept
  must demonstrate both.
]

With the target defined, we can go shopping for algorithms. Two families are in
wide production use and deliver these properties: *Operational Transformation* and
*Conflict-free Replicated Data Types*. A candidate who can define both, contrast
them honestly, and implement one owns this interview.

=== Approach A — Operational Transformation (OT)

#defterm([Operational Transformation (OT)])[
  A concurrency-control technique in which every edit is expressed as an
  *operation* — for plain text, `insert(position, char)` or `delete(position)` —
  and, whenever two operations are concurrent, one is *transformed* against the
  other: its position is adjusted so that it still does what its author meant on a
  document the other operation has already modified. Remember the `"AO"` failure
  above, where positions shifted under concurrency? Transformation is exactly the
  repair for that shift. OT is the machinery inside Google Docs, with a lineage
  running from the Jupiter system (1995) through Google Wave.
]

The transformation rules fit in a small matrix, and the matrix is the entire
algorithm. To apply operation `a` on a replica where the concurrent operation `b`
has already been applied, you transform `a` against `b` like this:

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

Read one row slowly to be sure the idea lands. Take "`insert(p_a)` vs
`delete(p_b)`: if `p_b < p_a`, shift `a` left by 1." Why left? Because a character
*before* your insert position has been removed, so every position after it moved
one slot toward the start of the document. Your insert still means "after the same
characters as before," so its index must follow the shift. Every other row is the
same idea in a different case: track what the already-applied operation did to the
text, and adjust the incoming operation so its *meaning* survives.

The whole of OT is this matrix plus one discipline: *every replica applies the
same operations in the same total order, transforming as needed.* Here is our
running example drawn as the classic convergence diamond — both paths away from
the concurrent state must land on the same document:

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

This little diamond repays a slow reading, because it *is* the problem and its
solution in one picture. Start at the top: both users see the same document
`"GO"` at revision 41. Now follow the left edge downward. Alice types first from
her own point of view, so her machine applies her insert immediately (remember
the 16 ms local-echo budget) and she sees `"AGO"`. Bob's machine, on the right,
does the symmetric thing: applies his delete locally and shows him `"G"`. At this
instant the two screens genuinely disagree — that is unavoidable, and fine,
because nobody has communicated yet.

Now the edits cross the network, and the bottom half of the diamond is where OT
earns its keep. On the left, Alice's machine receives Bob's `delete(1)` — but her
document is now `"AGO"`, where index 1 is the `G`, not the `O`. So her client
transforms Bob's operation against her already-applied `insert(0, 'A')`: the
insert happened at or before the delete position, shifting everything right, so
the delete becomes `delete(2)`. Applied to `"AGO"`, that removes the `O` and
yields `"AG"`. On the right, Bob's machine receives Alice's `insert(0, 'A')` and
transforms it against his already-applied `delete(1)`: the insert position is
before the delete, so the delete did not shift it, and the operation applies
unchanged to `"G"`, yielding `"AG"`. Both paths land on the bottom box — same
operations, same final document, both intentions preserved. When you can narrate
this diamond fluently at a whiteboard, the interviewer knows the hardest concept
in the chapter is safely yours.

#notebox([Where the total order comes from])[
  OT has a hidden precondition: every replica must transform against the *same*
  concurrent history, or the matrices produce different results on different
  machines. The standard way to arrange that is a *single sequencer per
  document*: the server assigns every operation the next integer *revision* (42,
  43, 44, …), and that assignment _is_ the total order. Clients send operations
  tagged with the revision they were based on; the server transforms each
  operation across any operations committed in between, and only then broadcasts
  it. We make this precise in the deep dives (Sections 1.11 and 1.13), where you
  will see that the sequencer turns "distributed consensus" into a counter and a
  loop.
]

=== Approach B — Conflict-free Replicated Data Types (CRDTs)

Before the second approach makes sense, you need the consistency vocabulary it
improves on.

#defterm([Eventual consistency])[
  A consistency model in which replicas that have stopped receiving new writes
  will *eventually* reach the same state. It promises convergence, but says
  nothing about *when* convergence happens, and nothing about what intermediate
  states look like — a replica might serve nonsense for an unbounded window before
  settling. Weak, but often enough.
]

#defterm([Conflict-free Replicated Data Type (CRDT)])[
  A data structure whose concurrent updates are merged by rules that are
  commutative (order does not matter), associative (grouping does not matter), and
  idempotent (duplicates do not matter). Those three properties together mean that
  replicas applying the same updates in *any* order, even with duplicates,
  provably converge. The upgraded guarantee is called *strong eventual
  consistency*: convergence as soon as updates are delivered, with no central
  ordering authority and no transformation step at all.
]

For text, the canonical CRDT trick is elegant: stop addressing characters by
integer positions — positions are exactly what shifts under concurrency, the
problem OT spends its matrix repairing — and instead give every character a
*unique, immutable, orderable identifier* at birth. In the RGA family of
algorithms, an insert is recorded as "insert this new character, with a fresh
globally-unique ID, immediately after character ID X." Because identifiers never
move, nothing ever needs transforming: concurrent inserts after the same
character interleave deterministically by ID order, and deletes merely mark a
character as a *tombstone* — present in the structure, invisible in the text.
Merging two replicas is set union, which is why any delivery order works. If this
sounds appealing, it is — Chapter 9 is a full-length treatment of CRDTs,
including an RGA text implementation in Rust, and it reads this chapter as "the
road not taken."

=== Choosing between them

Lay the two families side by side and the trade-off structure becomes visible —
neither dominates; each buys something the other cannot cheaply provide:

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
source talk describes, and the one Google Docs runs on. Walk through the reasoning
the way you would out loud. The sequencer's obvious cost is that it is a single
point of *ordering* per document — but is it a bottleneck? Section 1.5 already
answered that: a document peaks at ~150 ops/sec, which a single thread laughs at.
And what the sequencer buys is enormous: it collapses the hard problem into
"transform against a linear log," gives us version history almost for free (the
log *is* the history), and is simple enough to implement exactly right. We accept
the failover complexity of single-ownership, and we keep version vectors (next
section) for the edges of the design — reconnect, catch-up, and the offline
extension — where causal bookkeeping still matters.

#tip([Name the trade-off out loud])[
  Compare two candidates. The first says: "I'll use OT because Google Docs does."
  That earns nothing — it is an appeal to authority. The second says: "I'll use OT
  with a per-document sequencer. That gives me small messages and a linear history
  that makes version history trivial; in exchange I accept a single ordering point
  per document, which I mitigate with lease-based failover." Same design — but the
  second candidate has demonstrated the skill the interview actually measures.
  Every choice in this chapter is presented as a benefit purchased at a cost, and
  you should narrate yours the same way.
]

== Version Vectors: Tracking What Each Replica Has Seen

The OT diamond resolves the moment of concurrency, but a running system faces a
quieter bookkeeping question every few seconds: *which operations has this
particular client already received?* Think about when the question comes up. A
client's Wi-Fi drops for thirty seconds and reconnects — what should the server
send it? A user opens a document after a week away — where do you start? An
offline-editing extension needs to merge a laptop's airplane edits with the
server's state — which operations does each side lack? All three are the same
question in different clothes: compare "what you have seen" with "what exists."

Your first instinct might be timestamps — "give me everything after 14:32:07." We
already know why that fails: clock skew. Two machines' wall clocks routinely
disagree by seconds, sometimes minutes, and correctness cannot rest on that. What
we need is a *logical* notion of time — one that tracks "what caused what"
instead of "when the clock said."

#defterm([Logical clock / Lamport timestamp])[
  A counter, maintained by each participant, that ticks on every local event and
  rides along on every message; a receiver merges it by taking the maximum and
  ticking on. Logical clocks order events by *causality* rather than wall-clock
  time — if A's clock value is smaller than B's and causality flowed between them,
  A happened first. This is exactly the notion of "before" that distributed state
  synchronization needs, and it costs nothing but a few bytes per message.
]

#defterm([Version vector])[
  A Lamport clock generalized to many writers: a map from participant ID to a
  counter, where `{Alice: 3, Bob: 1}` reads as "I have seen 3 events from Alice
  and 1 from Bob." Two version vectors compare pointwise, and the comparison has
  exactly four outcomes. V₁ *dominates* V₂ — equivalently, V₂ happened-before V₁ —
  if every entry of V₁ is greater than or equal to V₂'s and at least one is
  strictly greater: V₁ has seen everything V₂ has, and more. If neither dominates,
  the states are *concurrent*: each has absorbed something the other has not. A
  version vector, in other words, is a compact summary of *precisely which causal
  history a replica has seen* — and that is exactly what catch-up logic needs to
  know.
]

Now, an honest simplification. In our design the server already assigns a single
integer revision per document through the sequencer, so in the *steady state* the
sync marker between server and client is just a scalar — "I am at rev 47." You do
not need a full vector when a total order exists; the integer is a complete causal
summary. Version vectors earn their keep at the *edges* of the design, where total
orders break down: when a reconnecting client's state was captured against a
snapshot rather than the live log, when replicas in different regions compare
notes, and in the offline extension where a client accumulated edits no server
saw. The comparison logic is identical in all three: if the server's knowledge
dominates the client's, send exactly the difference; if concurrent, compute a
two-sided diff.

#pitfall([The snapshot / version-vector trap])[
  The source talk's wry observation — a client "never received those writes on
  your local copy since your version vector was more up to date than the document
  snapshot" — describes a real and depressingly common production bug. Here is the
  scenario in slow motion. A snapshot of the document is written to one store,
  while the version metadata recording *which revisions that snapshot covers* is
  written to another, and the two writes are not atomic. A crash intervenes
  between them. Now a reconnecting client compares its version vector against
  *stale* snapshot metadata, concludes — correctly, given what it was told — that
  it is up to date, and is never sent the missing operations. The user sees a
  document silently behind everyone else's, and no error ever fires. The cure is
  atomicity between a snapshot and its version metadata; Section 1.12 shows the
  cheap way to get it, and defines the two-phase commit protocol the talk
  name-drops for exactly this seam.
]

== API & Protocol Design

With the correctness machinery understood, we can design the surface the system
shows the world. The first decision is that there are *two* surfaces, and saying
that out loud is itself worth credit:

- The *control plane* — create, rename, share, and open documents; fetch history.
  These are classic request/response operations: infrequent, latency-tolerant,
  and naturally stateless. Plain HTTPS REST is not merely adequate here, it is
  *correct* — anything fancier would be engineering theater.
- The *data plane* — the live editing session itself: join, send operations,
  receive operations, stream presence. This plane has opposite physics: a
  persistent, bidirectional, low-latency channel per client, held open for the
  whole session.

#defterm([REST])[
  An API style layered on HTTP in which resources — nouns like `/documents/{id}` —
  are manipulated with a fixed vocabulary of methods — verbs: `GET`, `POST`,
  `PATCH`, `DELETE`. Its defining discipline is statelessness: each request
  carries everything the server needs to answer it, so any server can handle any
  request. That is precisely what makes REST ideal for our control plane, where we
  want ordinary horizontal scaling and no session affinity.
]

#defterm([WebSocket])[
  A protocol (RFC 6455) that upgrades an ordinary HTTP connection into a
  long-lived, full-duplex channel: after an initial handshake, *either* side may
  send a message at *any* time, with only a few bytes of framing overhead per
  message. Full-duplex persistence is exactly what makes sub-150 ms propagation
  possible — the server pushes an edit the instant it commits, with no client
  polling loop and no per-message connection setup.
]

Why not the older real-time mechanisms? Each is worth a sentence, because the
interviewer may well ask:

#tbl(
  (0.85fr, 1.45fr, 1.1fr),
  header: (hcell[Mechanism], hcell[Behavior], hcell[Verdict]),
  body: (
    [Short polling], [Client re-asks "anything new?" every few seconds], [Latency measured in seconds; thousands of wasted requests — rejected],
    [Long polling], [Server holds each request open until data exists], [Near-real-time, but a fresh HTTP request per message burst — heavy at our scale],
    [Server-Sent Events], [Server → client push over HTTP; client sends via separate requests], [Workable, but asymmetric; WebSocket is cleaner for a two-way edit stream],
    [*WebSocket*], [One persistent, bidirectional connection], [*Chosen for the data plane*],
  ),
)

=== Control-plane endpoints

The control plane is deliberately unremarkable — you have seen a hundred APIs
like it, and that is the point. A resource per noun, a verb per operation:

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

Two of these deserve a second look. `GET /documents/{id}` returns not just the
document but its *current revision number* — the client needs that number to say
`last_seen_rev` when it joins the live session, so the open-then-join sequence is
how catch-up begins. And the `history`/`snapshot` pair is FR-5 made concrete:
list revisions to render the timeline UI, then fetch the document *as of* any
revision the user clicks.

=== Data-plane protocol (WebSocket messages)

After the REST `GET`, the client upgrades to a WebSocket and speaks a small JSON
protocol. Every message carries a `type`; the important ones:

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Message], hcell[Direction], hcell[Payload & semantics]),
  body: (
    [`join`], [client → server], [`{doc_id, auth_token, last_seen_rev}` — enter the session; `last_seen_rev` is the catch-up handle],
    [`joined`], [server → client], [`{doc_id, rev, snapshot, collaborators[]}` — current state, after any needed catch-up],
    [`op`], [client → server], [`{doc_id, base_rev, op, client_seq}` — one edit, based on `base_rev`, deduplicated by `client_seq`],
    [`ack`], [server → client], [`{client_seq, rev}` — "your edit is committed as revision `rev`"],
    [`op` (broadcast)], [server → client], [`{rev, author, op}` — a committed edit to apply (transform locally if you have pending edits)],
    [`presence`], [both], [`{cursor, selection, name}` — ephemeral, throttled, never persisted],
    [`sync`], [server → client], [`{rev}` / snapshot — sent when the client is too far behind to patch with ops],
  ),
)

A committed operation, on the wire, looks like this:

```json
{
  "type": "op",
  "doc_id": "d_8f31c2",
  "rev": 47,
  "author": "alice@example.com",
  "op": { "kind": "insert", "pos": 0, "ch": "A" }
}
```

Two fields in this little protocol carry the entire correctness story, and
interviewers probe both. The first is `base_rev` — the revision the client was
looking at when it made the edit. That single number is how the server *detects*
concurrency: if the document is at revision 52 and your operation says
`base_rev: 49`, then revisions 50 through 52 were invisible to you, your edit is
concurrent with them, and the server must transform it across those three
revisions before committing (Section 1.11 walks the pipeline; Section 1.13
implements the loop). The second is `client_seq`, which makes the whole protocol
survivable on real networks:

#defterm([Idempotency / idempotency key])[
  An operation is _idempotent_ if performing it twice has exactly the same effect
  as performing it once. Why you should care: real networks retry. Connections
  drop *after* the server processed your message but *before* you heard the
  acknowledgment, and the client's only sane move is to send the operation again.
  A unique client-supplied key per operation — here, the pair `(client_id,
  client_seq)` — lets the server recognize the duplicate delivery and answer with
  the original result instead of applying the edit twice. This is the difference
  between at-least-once *delivery*, which networks give you whether you want it
  or not, and effectively exactly-once *effect*, which you must engineer. Chapter
  10 builds an entire system on this idea.
]

== Data Model & Storage

What do we actually persist? Four entities, each with one clear job — and notice,
as you read the table, that each entity has a *different access pattern*, which is
the fact that will choose our storage engines for us:

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

Two of these storage ideas are the ones interviewers lean forward for, so let us
give each a proper definition and — more importantly — the reasoning behind it.

#defterm([Operation log (event log)])[
  The discipline of storing every change as an immutable, ordered, append-only
  record instead of overwriting state in place. The current state is always
  *derivable* — replay the log from the beginning and you rebuild the present.
  For us this single choice cascades beautifully: version history (FR-5) is free,
  because history is what we store; auditing is free, for the same reason; and
  crash recovery is just replay. There is even a performance dividend: appending
  to the end of a file is the fastest write a storage device can do — sequential
  I/O, no random updates, no in-place locking of hot rows.
]

#defterm([Snapshot])[
  A materialized copy of the full document as of a specific revision. Pure logs
  have an embarrassing read problem: replaying two billion operations to open one
  document is absurd. So every _N_ operations (say 500), we freeze the current
  text into a snapshot, and reconstruction becomes `latest snapshot + the handful
  of operations since`. Keep the hierarchy straight in your head and say it out
  loud in the interview: snapshots are a *read optimization* over the log, never
  the source of truth — the log is. You can delete every snapshot and lose
  nothing but time.
]

#notebox([Why three stores and not one database])[
  Look back at the table and you will see the access patterns pulling in three
  directions. The metadata is small, hot, and transactional — it wants indexes,
  conditional updates, and joins, the home turf of a PostgreSQL-class store. The
  snapshots are large, immutable, and cold — they want cheap object storage, an
  S3-class blob store, where durability is high and nobody ever asks for a
  partial update. The operation log is append-only and strictly ordered per
  document — it wants a log-structured store, Kafka-class or Cassandra-class.
  Choosing one engine per access pattern, and being able to *say why each
  property matches*, is exactly the answer this section exists to elicit. Name
  the properties first and the brands second; the brands are replaceable, the
  reasoning is the answer.
]

== High-Level Architecture

Now we can assemble the machine. Section 1.5 handed us the organizing principle —
*a thin, stateless, horizontally scaled connection tier in front of a small,
stateful, correctness-critical core* — and every box you are about to see exists
to serve that principle. Here is the whole system at a glance; we will walk
through it slowly right after.

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

Do not let the nine boxes blur together — each has one job, and the *shape* of
the diagram is the argument. Read it the way traffic flows.

Start at the top left with the clients. Every client holds two logical
connections: an ordinary HTTPS channel for control-plane work (creating a
document, fetching history), and one long-lived WebSocket for the editing
session. Both pass through the load balancer, whose only job is to spread
connections across the stateless tiers behind it — it makes no per-document
decisions and holds no per-document state, which is why it can be boring,
redundant, and invisible.

The next row splits the two planes we designed in Section 1.8. The *REST API
service* is a stateless request/response tier: any request can land on any
instance, so scaling it means adding instances, the dullest kind of scaling there
is. The *WebSocket gateway fleet* is where the million-connection problem from
Section 1.5 lives: each gateway is a commodity box holding tens of thousands of
mostly-idle connections, terminating TLS, and forwarding messages. It is
stateless in the only sense that matters — it knows nothing about documents — so
a client whose gateway dies simply reconnects to any other. We will never have to
think hard about this tier again, and that is exactly why it exists: it absorbs
the huge, dumb, connection-count load so the next tier does not have to.

That next tier — the *collaboration service*, drawn in blue because it is the
heart of the design — is where every operation on a document converges on the
single node that owns that document. Follow the solid arrow labeled "ops in":
gateways forward client operations here, routing by `doc_id`. The owning node
sequences, transforms, and commits each operation (that is Section 1.11's whole
story), and then — the dashed "broadcast" arrow — pushes the committed result
back to the gateways, which fan it out to every connected editor. One owner per
document is the load-bearing decision of the entire architecture, so the insight
box below is devoted to it.

The bottom row is storage, and it mirrors Section 1.9's access patterns. Three
teal arrows leave the collaboration node, one per store. The longest arrow,
sweeping left to the *operation log*, is the write that matters most: every
committed operation is appended here, in revision order, and this log is the
source of truth — everything else can be rebuilt from it. The middle arrow,
"snapshot every N ops," is the read optimization: periodically the node freezes
the document text into the blob store so that future opens and reconnects are
O(1) instead of O(history). The short arrow to the *metadata DB* keeps the small,
hot, transactional records — documents, ACLs, and the current revision counter.
And off to the right, drawn in amber and *dashed* on purpose, is the *presence
cache*: cursors flow gateway-to-cache-to-gateway without ever touching the
sequencer or the log. The dashed styling is a design statement — presence is
ephemeral, lossy, and throttled, and drawing it on the same solid lines as edits
would claim a guarantee we deliberately do not provide.

Finally, the caption under the diagram records the one routing rule everything
else depends on. Here it is again, with its full weight:

#insight([The one routing rule that makes it all work])[
  *All traffic for a given document flows through the single collaboration node
  that owns it.* When a gateway receives an operation, it looks up `doc_id →
  owner` in a routing table — a cheap read — and forwards. Because every operation
  on a document passes through one owner, the owner's revision counter *is* a
  total order, and a total order is exactly what OT needs (Section 1.6). Ownership
  is not permanent: if a node dies, its lease expires and ownership migrates
  (Section 1.16). The invariant is only that there is *exactly one owner at a
  time*. Notice what this gives us: we never run a consensus protocol on the edit
  path at all. Consensus is what you need when many nodes must agree on an order;
  we sidestepped the need by construction.
]

For completeness, the same responsibilities as a checklist — use it in the
interview to make sure you have justified every box you drew:

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

== Deep Dive: The Edit Pipeline, Step by Step

Architecture diagrams tell you where things live; sequence diagrams tell you what
*happens*. Let us follow one keystroke the whole way from Alice's keyboard to
Bob's screen, because every design decision from the last six sections fires
somewhere along this path. The setup is chosen to make it interesting: document
`d_8f31c2` is at revision 46, but Alice believes it is at revision 42 — four
operations from other editors are committed on the server and have not yet
reached her. Her edit is therefore *concurrent* with four committed operations,
and the system has to cope.

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

Read the diagram top to bottom — time flows downward, each column is one of the
participants, and every arrow is one message crossing the network. Then let us
narrate the seven numbered steps, because each one exists for a reason you should
be able to defend:

+ *Send (Alice → gateway).* The instant Alice types, her client applies the
  keystroke to her *local* document — this is the local echo that keeps edit
  latency under 16 ms; her screen never waits for the network. In parallel, the
  edit goes out as `op{base_rev: 42, …}` carrying her next `client_seq`. Both
  fields are load-bearing: `base_rev` honestly reports what she had seen when she
  typed, and `client_seq` makes the message safe to retry.
+ *Route (gateway → collaboration node).* The gateway does *no* correctness work
  — it does not even understand the operation. It reads `doc_id`, consults the
  routing table, and forwards to the node that owns this document. Keeping the
  gateway dumb is what keeps it stateless, and statelessness is what lets the
  fleet scale to a million connections.
+ *Sequence & transform (the collaboration node, highlighted).* This is the step
  where the chapter's core challenge is actually solved, once per operation. The
  owner compares `base_rev: 42` with the current revision 46 and thereby *knows*
  Alice's edit is concurrent with revisions 43–46. It transforms her operation
  against each of those four committed operations, in order, using the matrix
  from Section 1.6 — and only then stamps the result with the next revision, 47.
  From this moment, her edit has a fixed place in the document's history.
+ *Commit (collaboration node → op log).* The transformed operation is appended
  to the operation log, and the append must become durable before anything else
  happens. Once it is durable, the edit is *committed*: it can never be lost,
  never be reordered, never be un-seen. The pitfall box below explains why this
  step must precede the next one.
+ *Broadcast (collaboration node → gateways).* Only after durability does the
  committed operation flow back to the gateway tier, which fans it out to every
  connected editor of the document — including Alice's own gateway, though her
  client will mostly treat the broadcast as a formality.
+ *Apply (gateway → Bob).* Bob's client checks the incoming `rev` against its own
  state. Bob is fully caught up, so the operation applies verbatim. Had Bob been
  nursing a *pending* local edit — typed, echoed, not yet acked — his client would
  first transform that pending edit against the incoming operation, using the
  same matrix the server runs. The transform code is symmetric on purpose: one
  implementation, shared by client and server, keeps local echo and committed
  state from drifting apart.
+ *Acknowledge (gateway → Alice).* Finally, the `ack` tells Alice her operation
  is committed as revision 47, and her pending buffer clears. Notice what her
  eyes experienced: the character appeared instantly at step 1, and nothing
  visible happened at step 7. The local echo and the committed result are
  identical *by construction* — that is the user-visible payoff of all this
  machinery.

#pitfall([Order matters: commit before broadcast])[
  It is tempting to reorder steps 4 and 5 — broadcast first, persist "in
  parallel," save a few milliseconds. Resist it. If a node crashes after the
  broadcast but before the durable append, you have shown users edits that no
  longer exist; on recovery, the official history contradicts what people watched
  happen, and there is no clean way to retract a character from a collaborator's
  screen. The rule is absolute: durability first, *then* visibility. It is the
  write-path version of "do not promise what you cannot guarantee," and Chapter
  11's write-ahead log is the same rule wearing different clothes.
]

== Deep Dive: Snapshots, Catch-Up & the Two-Phase Lesson

Two housekeeping jobs remain before the design is operationally complete, and
they live at the same seam — the boundary between the operation log and the
snapshot store. The first is making *open and reconnect fast*; the second is
keeping a snapshot and its metadata *atomic*. Both are easy to describe and easy
to get subtly wrong.

=== Catch-up: what to send a rejoining client

When a client joins with `join{last_seen_rev}`, the owning node compares that
number against the current revision `R` and picks one of three strategies. Think
of it as a cost comparison: what is the cheapest way to make this client current?

- *Close behind* (`R - last_seen_rev` is small, say ≤ 500): send the missing
  operations straight from the log. The client transforms any pending local edits
  across them and is current in milliseconds. This is the common case — network
  blips are short.
- *Far behind* (the laptop that was closed for a week): replaying tens of
  thousands of operations is strictly slower than sending their *result*. Send
  `latest snapshot + operations since the snapshot's base_rev`. This is exactly
  what the snapshot store exists for; without it, every long-absent open would be
  a full log replay.
- *Offline edits* (the extension): now the client is not merely behind — it has
  edits of its own that the server never saw. A scalar revision cannot express
  that, so the client presents its *version vector* (Section 1.7) instead. The
  server computes the set difference — the operations the client missed — and the
  client rebases its offline operations on top, transforming each across the
  diff. Notice why vectors and not timestamps, one more time: they compare
  *causal* histories, and causality is the only "when" both sides can agree on.

=== The atomicity requirement

A snapshot without correct metadata is worse than no snapshot at all. The
metadata — above all `base_rev`, the revision through which the snapshot covers
the log — is what catch-up logic *trusts*. Stale metadata is precisely the
failure from Section 1.7's pitfall: the client compares its version against a
lie, concludes it needs nothing, and silently misses writes forever. So two
writes must succeed or fail *together*: the snapshot blob itself, and the
`{snapshot_pointer, base_rev}` record in the metadata DB. Two stores, one atomic
outcome — the classic distributed-commit problem.

#defterm([Two-phase commit (2PC)])[
  The textbook protocol for committing one atomic operation across *multiple*
  stores. In phase 1 (_prepare_), a coordinator asks every participant "can you
  commit?" and each participant does everything short of committing, then votes
  yes or no. In phase 2 (_commit_), the coordinator broadcasts the verdict:
  commit if all voted yes, abort otherwise. 2PC delivers genuine cross-store
  atomicity, but the price is steep: it is *blocking* — a coordinator that crashes
  at the wrong moment leaves participants locked, holding resources, unable to
  proceed — and it costs two network round trips. So the engineering question is
  never "how do I run 2PC?" but "how do I get the same guarantee more cheaply?"
]

For our seam, three constructions are on the table, in increasing order of
machinery:

+ *One store, one transaction.* If the snapshot blob and its metadata happen to
  live in the same database, a single local transaction gives atomicity for free
  and 2PC never enters the conversation. Always check this option first; sometimes
  a schema decision makes it available.
+ *Immutable blob + conditional pointer update* — our choice, and worth
  understanding line by line. First, write the snapshot to the blob store under a
  content-addressed name, so the blob is immutable and self-identifying. *Only
  after* that write is durable, update the metadata row with a conditional
  compare-and-swap: `UPDATE … WHERE base_rev = <old>`. Now consider every crash
  point. Crash before the blob write: nothing happened. Crash between the steps:
  an *orphan blob* sits in the store — wasted bytes, which a garbage collector
  reclaims, but *never incorrect*, because nobody's metadata points at it. Crash
  during the pointer update: the conditional write fails or completes atomically,
  by the store's own row-level guarantees. No coordinator, no blocking, no second
  round trip — atomicity assembled from idempotence and ordering.
+ *Full 2PC* remains for the case where two genuinely independent systems must
  commit together and neither trick above applies. Name it in the interview —
  and then argue you rarely need it. Knowing the expensive tool and declining it
  is stronger than not knowing it.

== Deep Dive: Rust Reference Implementation

The concurrency core of this entire system is small enough to hold in your head —
small enough, in fact, to show in full. Three pieces: the wire protocol types,
the OT transform matrix with its convergence test, and the version vector. As
you read, notice how little code the architecture's discipline has bought us.

=== Protocol types

The data-plane messages from Section 1.8, as Rust types, with serde deriving the
JSON representation:

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

The `#[serde(tag = "type")]` attribute is what makes the JSON look exactly like
the protocol table — a `type` field distinguishes the variants, so the wire
format and the type system say the same thing in two languages.

=== The OT transform matrix

This is Section 1.6's table made executable. `transform(a, b, a_wins_ties)`
returns operation `a` adjusted to apply *after* the concurrent operation `b` has
been applied — or `None` when `a` has been transformed into a no-op:

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

Two disciplines in this code deserve a sentence each, because both are classic
production bugs when ignored. First, `apply` works in *character* positions, not
byte offsets — Rust strings are UTF-8, and an edit protocol that confuses the two
will corrupt any document containing an emoji the day it ships. Second, the
delete/delete collision returns `None`: when both users deleted the same
character, the second delete is transformed into a no-op, which is exactly the
"both intentions honored" outcome the definition of intention preservation
demands.

And here is the convergence diamond from Section 1.6 — the picture we walked
through — expressed as an executable test, so the claim "both paths converge to
`"AG"`" is checked, not asserted:

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

Step 3 of the pipeline — "transform against revs 43–46" — is where the server's
copy of the algorithm lives. The owning node keeps one `DocSession` per active
document, and when an operation arrives based on an old revision, the session
walks it forward across everything committed since:

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

Stand back and look at how unglamorous this is: a counter, a vector, a `for`
loop. There is no consensus protocol, no lock service, no distributed anything —
because the architecture already did that work. Since *all* operations for a
document funnel through one owner, the "distributed consensus" the problem seemed
to demand has been reduced to no consensus at all. When you present this in an
interview, that sentence is the punchline of the whole chapter.

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

Two details in the comparison deserve your attention, because both are easy to
get wrong on a whiteboard. Iterating `self.0.keys().chain(other.0.keys())` —
rather than just one side's keys — is what makes the comparison correct when one
vector knows about a participant the other has never heard of: the missing entry
counts as zero on both sides. And the two-boolean accumulation (`less`,
`greater`) is what makes *concurrency* detectable: if some entry is less and some
other entry is greater, neither vector dominates, and the honest answer is
`Concurrent`. With this type in hand, Section 1.12's catch-up decision collapses
to three lines: if the client's vector is `Before` the server's, send the
operations it lacks; if `Equal`, send nothing — and, per Section 1.7's pitfall,
verify the *snapshot metadata* told the same story; if `Concurrent`, the client
carries offline edits, so send the diff and rebase.

== Deep Dive: Presence & Live Cursors

Presence — "who is here, and where exactly is their cursor" — looks like a
trivial side feature, and it hides one elegant detail that interviewers love to
probe: *cursor positions are text positions*, so they are subject to exactly the
same shifting problem as edits. Suppose Alice's cursor sits at position 10, and
Bob inserts three characters at position 4. If we render Alice's cursor at
position 10 unchanged, we draw it three characters early — on the wrong letter,
silently. The fix is already built: clients transform remote cursors against
every incoming operation using the *same* OT matrix as edits, so a cursor is just
an operation-free position that rides the transform rules. The server never
computes cursors at all; it relays them, and each client keeps every remote
cursor correct locally.

Beyond that detail, three design rules keep presence cheap, and each is really
an application of one principle — *presence is disposable*, so nothing expensive
should ever be spent on it:

- *Never persist it.* Presence flows through the ephemeral cache and the
  broadcast path, refreshed by a client heartbeat every few seconds. If the whole
  presence tier vanished this instant, the only consequence would be that cursors
  reappear within one heartbeat — which is why the architecture diagram draws it
  as a dashed, separate path off to the side.
- *Don't sequence it.* Presence messages carry no `rev` and bypass the operation
  log entirely. Ask yourself why: a stale cursor for 100 ms is invisible to
  users, but a stale *edit* is a correctness bug. Paying sequencer and durability
  costs for data nobody will ever verify is the classic over-engineering trap,
  and declining it out loud is worth credit.
- *Throttle it.* Cursor movement fires dozens of events per second per editor;
  left unshaped, presence would dwarf edit traffic. Cap updates at, say, 10 per
  second per client — fifty editors then produce 500 tiny messages a second,
  which the per-document owner fans out without breaking stride.

== Scaling & Sharding

#defterm([Sharding (horizontal partitioning)])[
  Splitting data or work across many machines by a key, so that each machine owns
  a disjoint slice. Sharding is the fundamental answer to "one machine is not
  enough": pick the right key and the system grows by *adding* machines rather
  than by growing them — horizontal rather than vertical scale. The art is
  entirely in the choice of key: it decides whether load spreads evenly, and
  whether the data that must be together stays together.
]

Every tier of our system shards by its natural key, and walking the tiers is a
good way to see why the keys differ:

- *Gateways* hold no document state at all, so any consistent routing works —
  connections balance across the fleet, and a reconnect can land anywhere. When
  there is no state, the sharding question answers itself.
- *Collaboration nodes* are sharded *by document*, with a routing service that
  maps `doc_id → owner`. Ownership is granted as a *lease* — a time-limited claim
  the node must keep renewing. If a node crashes, its leases expire on their own,
  the routing service assigns a new owner, and the invariant "exactly one
  sequencer per document" survives the failure with no human involved.
- *The operation log, snapshots, and metadata* are sharded by `doc_id` as well,
  so all of a document's data lives together on one shard. Co-location is what
  keeps the commit path — append the op, bump the revision — a single-shard,
  single-round-trip affair.

#insight([The 50-editor cap is a load-shedding decision])[
  Why can a document never become a "hot shard" that melts its owner? Look back
  at Section 1.2: we capped concurrency at fifty editors. That product decision
  has an enormous architectural dividend — it bounds per-document load so tightly
  that the single-owner design can never be overwhelmed by traffic alone. A
  live-blog with a million *writers* would need something else entirely (a tree
  of sequencers, or CRDTs with no central order), and the honest thing to say in
  the interview is exactly that: "my single-owner design is safe *because* of
  this cap; lift the cap and I redesign." Naming which NFR protects you from
  which failure mode is precisely the reasoning interviewers listen for.
]

== Failure Modes & Recovery

A senior answer enumerates what breaks *before* being asked — not because
interviewers enjoy gloom, but because a design that only works when nothing
fails is a design that does not work. Walk the table slowly; each row is a small
argument about why the system survives:

#tbl(
  (auto, 1fr),
  header: (hcell[Failure], hcell[Handling]),
  body: (
    [Client disconnects], [Its edits are already durable in the log (that is what commit-before-broadcast bought us). On reconnect: `join` with `last_seen_rev`, catch up per Section 1.12. Its presence entry simply expires on its own.],
    [WebSocket gateway dies], [Clients reconnect to any other gateway — they are stateless, so any will do. In-flight unacknowledged operations are resent, and `client_seq` idempotency makes the retry harmless.],
    [Collaboration node dies], [The document's lease expires; the routing service assigns a new owner, which rebuilds session state as `latest snapshot + log tail` and resumes sequencing. Clients experience a reconnect, not data loss.],
    [Duplicate message delivery], [Impossible to prevent on real networks — so we make it harmless instead: `client_seq` idempotency on the write path, revision numbers on the read path (already have rev 47? ignore the re-broadcast).],
    [Op-log replica loss], [The log is replicated (3× is standard); a lost replica is replaced from its peers, and the source of truth survives any single loss.],
    [Network partition], [A client cut off from the server keeps editing locally and rebases on reconnect via the version-vector diff (Section 1.12) — or shows "offline, changes will sync," if we choose availability over freshness. A partitioned *server-side* minority, by contrast, refuses ownership transfers: on the ordering authority, correctness beats liveness.],
  ),
)

Step back and notice the pattern across the rows, because it generalizes far
beyond this chapter: *stateless things are replaced, stateful things are rebuilt
from the log, and duplicates are made harmless rather than prevented.* If you
classify your components along those three lines, failure handling stops being a
list to memorize and becomes a reflex.

== Trade-offs & Alternatives

The design is now complete, and it is time for the most honest section of the
chapter. Every architecture is a bundle of purchased benefits and accepted costs;
a candidate who recites only the benefits has not finished the answer. Here is
the whole ledger:

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Benefit purchased], hcell[Cost accepted]),
  body: (
    [Per-document sequencer + OT], [Small messages, a total order, free version history, simple reasoning], [A single point of *ordering* per doc (mitigated by lease failover — seconds of unavailability on crash); the OT matrix must be exactly right],
    [CRDT instead], [No sequencer; offline and peer-to-peer for free], [Per-character IDs and tombstones; heavier storage and garbage collection; harder to bolt on a clean linear history],
    [WebSocket data plane], [Sub-150 ms push; bidirectional], [A million long-lived connections to hold; load balancers must tolerate them],
    [Op log as source of truth], [History, audit, replay, recovery — all free], [Storage growth (~550 GB/day at our scale) and the snapshot machinery that keeps reads fast],
    [Single-region write ownership per doc], [No cross-region consensus anywhere on the hot path], [Editors far from the owner's region see higher propagation latency],
  ),
)

Read the first row one more time, because it is the whole interview in miniature:
we bought simplicity and a free feature (history) by accepting a single point of
ordering — and then we *engineered the cost down* with lease failover, rather
than pretending the cost did not exist. That rhythm — benefit, cost, mitigation —
is the voice of every strong system design answer.

#notebox([PACELC, briefly])[
  A refinement of the CAP theorem worth having at your fingertips: *if* there is
  a Partition, a system must choose between Availability and Consistency; *else*,
  in normal operation, it chooses between Latency and Consistency. Our design
  makes its choices per-subsystem rather than globally: the edit path picks
  *consistency* on both branches (single owner, total order, commit before
  broadcast), while presence picks *availability and latency* (ephemeral,
  best-effort, never persisted). Different subsystems may legitimately make
  different PACELC choices — and saying which subsystem chose what, and why, is a
  far stronger answer than declaring the whole system "CP" or "AP."
]

== Observability & SLOs

#defterm([SLI / SLO])[
  A _Service Level Indicator_ is a measurable quantity — for example, propagation
  latency at the 95th percentile. A _Service Level Objective_ is its target —
  "p95 \< 400 ms." SLOs are how "the system feels slow" becomes an engineering
  signal: each SLO carries an *error budget* (how much violation you can afford
  per month), and the budget, not anyone's feelings, decides when to stop shipping
  features and start fixing reliability.
]

What do we instrument, at minimum? Per-document ops/sec and transform rates
(the health of the core loop); end-to-end propagation latency, measured *on the
client* and tagged by region (the user-visible promise); ack latency (the writer's
promise); WebSocket connection counts and message rates per gateway (the
million-connection tier); the catch-up size distribution — where reconnect storms
reveal themselves before they hurt; snapshot lag (`current_rev -
snapshot.base_rev`), which tells you whether opens are drifting toward O(history);
and the lease-failover count, which should be near zero and interesting when it
is not.

One operating principle ties the list together: *alerts fire on SLO burn, not on
individual machine failures.* The failure table in Section 1.16 exists precisely
so that single failures are non-events; paging a human because one gateway died
would mean the redundancy was decorative.

== Interview Wrap-Up

The interviewer still has ten minutes. Here are the follow-ups that usually
arrive, with the shape of a good answer for each:

- _"Rich text?"_ — Operations gain attributes (bold ranges, styles, embeds); the
  transform matrix grows cases, but the architecture — sequencer, log, snapshots —
  does not change. A reassuring answer, because it is true.
- _"Comments and suggestions?"_ — Anchored to character ranges, and those ranges
  transform exactly like cursors (Section 1.14). They live in the metadata DB,
  off the hot path, because they are read-side annotations, not document content.
- _"End-to-end encryption?"_ — Now the server cannot read content, so server-side
  OT is impossible — you cannot transform what you cannot parse. This single
  requirement pushes you all the way to client-side CRDTs. A beautiful example of
  one requirement that *re-architects* the core; say so explicitly.
- _"5,000 simultaneous editors?"_ — Our 50-editor cap is precisely what licenses
  the single sequencer; at a hundred times that, shard the document itself or move
  to CRDTs. (Notice this is Section 1.15's insight, arriving as a question.)
- _"Undo?"_ — Per-user inverse operations, transformed through the log like
  everything else. Easy to describe, subtly hard to make *intuitive* — whose
  edits should your undo cross? Mention it, scope it, do not build it live.

*If you remember five things from this chapter:*

+ The product is a distributed-state synchronizer wearing a text editor's
  clothes; design the synchronizer and the editor takes care of itself.
+ Convergence plus intention preservation is the correctness bar; locks and
  last-writer-wins both fail it, each in an instructive way.
+ A per-document total order — the sequencer — reduces "distributed consensus" to
  a counter and a transform loop.
+ Commit durably, then broadcast: never show a user an edit you cannot guarantee.
+ Snapshots and their version metadata commit atomically, or reconnecting clients
  silently miss writes (Section 1.12).

== Summary & Further Reading

Let us close the loop. We designed a real-time collaborative plain-text editor
for 10M daily users: a stateless WebSocket gateway tier holding a million
connections; a collaboration service that owns each document and imposes a total
order on its operations; operational transformation to merge concurrent edits
while preserving their authors' intentions; an append-only operation log as the
source of truth, with periodic snapshots to keep reads fast; version vectors for
catch-up and offline diffing; and idempotent protocols that survive everything
real networks do. If the design felt inevitable by the end, that is the
estimation and the core challenge doing their work — the architecture was
*derived*, not invented.

*Primary source for this chapter:*
- #link("https://www.youtube.com/watch?v=YCjVIDv0zQY")[*“12: Design Google Docs/Real Time Text Editor”* — Systems Design Interview Questions With Ex-Google SWE (Jordan has no life)] — the mock-interview walkthrough this chapter expands.

*Foundations worth reading:*
- Ellis & Gibbs, _Concurrency Control in Groupware Systems_ (1989) — the original OT paper.
- Nichols et al., _Jupiter: high-latency collaboration_ (1995) — OT with a central server, the direct ancestor of our design.
- Shapiro et al., _Conflict-free Replicated Data Types_ (2011) — the CRDT formulation; our Chapter 9 builds directly on it.
- Google Wave's OT whitepapers, and Figma's engineering blog on multiplayer — production war stories from both families.

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
    [Latency], [Cause → observable effect; here: local echo \< 16 ms, propagation \< 150 ms],
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

#v(1.2em)
#align(center)[#text(fill: slate, size: 9.5pt)[
  — End of Chapter 1 · Next: Chapter 2 —
]]
