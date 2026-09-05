// ============================================================================
//  CHAPTER 8 — Designing a Database Index: How B-Trees Work
//  Source: "How do B-Tree Indexes work?" — Systems Design Interview: 0 to 1
//  with Google Software Engineer (channel: Jordan has no life)
//  Link: https://www.youtube.com/watch?v=Z2OaqmxiH20
// ============================================================================

#import "../template.typ": *

= Designing a Database Index: How B-Trees Work

#notebox([Problem source])[
  This chapter solves the problem posed in the talk _"How do B-Tree Indexes
  work?"_ from the series _Systems Design Interview: 0 to 1 with Google
  Software Engineer_ (channel: _Jordan has no life_). Unlike the product
  chapters, this is a *fundamentals* deep dive — the interviewer asks you
  to design the index structure of a relational database's storage engine:
  something that answers point lookups and range scans in milliseconds over
  billions of rows, survives a write-heavy workload, and lives on hardware
  whose physics you must respect. It is also the keystone chapter: Chapters
  5 and 6 stored data in "the database"; this chapter designs what they
  were standing on. All terms are defined before use; all reference code is
  Rust with deterministic tests.
]

== The Problem Statement

The interviewer draws a table with a billion rows and says:

_"Queries filter on equality (`email = ?`) and on ranges with ordering
(`created BETWEEN ? AND ?`, `ORDER BY created`). The table lives on disk.
Design the index structure that makes those fast — and explain exactly why
yours beats the alternatives."_

Take the prompt's last clause seriously — "explain exactly why yours beats
the alternatives" is the actual question. The B+ tree has been the standard
answer for fifty years, and reciting it earns you nothing; the interview
tests whether you can *re-derive* it from first principles, so that when the
follow-up twists the constraints (writes dominate? keys are huge? data fits
in RAM?) your answer moves with the physics instead of collapsing with the
recitation. And the physics here is unusually well-defined: the bottleneck
is not CPU or capacity but *disk I/O shape* — every random read costs ~10⁵
times a memory reference, so the entire game is minimizing the number of
disk pages touched per operation. Every design decision in this chapter —
page-sized nodes, separators, linked leaves, the write-ahead log — is that
one minimization wearing a different costume. Once you see that, the chapter
stops being a taxonomy and becomes a single argument you can reconstruct on
any whiteboard.

#defterm([Index])[
  A redundant, derived data structure that maps a search key to the
  location of full rows, maintained by the database on every write. An
  index trades write cost and space for read speed: every `INSERT` pays to
  keep it current, and every matching query repays that cost a
  thousandfold. "Adding an index" is never free — it is a bet that reads
  outnumber writes.
]

#defterm([Point lookup / range scan / sorted iteration])[
  The three read shapes an index can serve: _point lookup_ (`key = ?`),
  _range scan_ (`lo ≤ key ≤ hi`), and _sorted iteration_ (`ORDER BY key`
  without a sort step). A structure that serves all three is dramatically
  more valuable than one serving only the first — this asymmetry eliminates
  the hash index from the running almost immediately (Section 8.7).
]

Linger on the second definition's asymmetry, because it is the first
domino. The prompt mentions equality *and* ranges *and* ordering — three
read shapes — and any structure you propose will be judged against all
three simultaneously. A hash table is the perfect answer to one of them and
a non-answer to the other two; a sorted file answers all three for readers
and declares bankruptcy on writes. Hold both failures in mind: the winning
structure will be the one that refuses to choose, and understanding why
that refusal is *possible* — localized mutation inside a sorted, page-aligned
hierarchy — is the chapter in one sentence.

== Scope & Clarifying Questions

Even a fundamentals prompt has a workload hiding in it, and surfacing that
workload is your first move. Each of these answers steers the design in a
direction you should be able to name:

#tbl(
  (auto, 1fr),
  header: (hcell[Candidate asks], hcell[Interviewer answers]),
  body: (
    [Workload shape?], [OLTP: many small point reads/writes, plus frequent range scans and ORDER BY pagination],
    [Data resident where?], [On disk (or SSD); tables far exceed RAM. Indexes may be partially cached],
    [Read/write mix?], [Mixed; neither extreme. Reads dominate slightly, writes must stay cheap],
    [Key types?], [Integers, strings, composite (multi-column) keys],
    [Concurrency?], [Mention latching strategy; don't design a full lock manager],
    [Durability?], [Committed writes must survive crashes — bring in a WAL when you get to the write path],
    [Distribution?], [Single node. Sharding is Chapter 5's topic; indexes replicate/shard with their table],
  ),
)

Three answers do the heavy lifting. "OLTP with frequent range scans"
confirms the three-read-shapes requirement and rules out the write-first
structures. "Tables far exceed RAM" is the constraint that makes this a
*disk* design at all — if everything fit in memory, Chapter 6's ordered
maps would finish the interview in five minutes, and the whole page-I/O
apparatus would be overhead. "Mixed; neither extreme" is the quietest and
most decisive: it is the read/write ratio that Section 8.11's B+-vs-LSM
verdict turns on, and you should note that the interviewer has just handed
you that verdict's input. The last row's "single node" is a mercy — say
thank you and take it.

#notebox([Agreed scope])[
  + Design the on-disk index structure for a single-node relational storage
    engine: *point lookup*, *range scan*, *sorted iteration*, *insert*,
    *delete*.
  + Respect disk physics: I/O in fixed-size pages; random I/O is the
    scarce resource.
  + Cover the write path (buffer pool, WAL, splits) and the B+ tree's
    classic variants (clustered, secondary, covering, composite).
  + Position the LSM tree as the write-optimized alternative and know when
    it wins.
  + Out: concurrency control protocols, distributed indexes, query
    optimization beyond index selection basics.
]

== Functional Requirements

Six requirements, and they read like the spec of an abstract data type —
because that is exactly what an index is. The discipline is in the
qualifiers: not "fast lookups" but "a small, *bounded* number of page
reads regardless of table size"; not "support deletes" but "delete *without
slow decay*." An index that degrades gracefully in the small and
catastrophically in the large is worse than none, because the catastrophe
arrives in production, at scale, on a weekend.

+ *FR-1 — Point lookup.* `key → row location` in a small, bounded number
  of page reads regardless of table size.
+ *FR-2 — Range scan.* All keys in `[lo, hi]` in sorted order, touching
  only pages that contain them.
+ *FR-3 — Sorted iteration.* Full or partial ordered traversal (for
  `ORDER BY ... LIMIT`) without an external sort.
+ *FR-4 — Insert.* Add a key, maintaining the structure's invariants, with
  bounded page writes.
+ *FR-5 — Delete.* Remove a key, keeping pages reasonably full (no slow
  decay into a sparse, space-wasting structure).
+ *FR-6 — Crash safety.* No committed state is lost and the structure is
  never corrupted by a crash mid-write (with the WAL, Section 8.10).

Read FR-2's "touching only pages that contain them" twice — it smuggles in
the locality requirement that will later justify the B+ tree's linked
leaves. A range scan that touches one random page per qualifying row is a
point-lookup loop in a trench coat; the requirement says the *physics* of
the scan must be sequential, not just its result set. And FR-6 is the
requirement that silently doubles the design: any structure you propose
must survive being interrupted *between* page writes, which is why the
write path (Section 8.10) is a co-designed partner of the structure, not an
afterthought.

== Non-Functional Requirements

Two definitions first, because the NFR table's every row is stated in their
vocabulary:

#defterm([Page / block I/O])[
  Disks do not read bytes; they read *pages* — fixed-size blocks (4–16 KB)
  that are the atomic unit of I/O and of the buffer pool. Every structure
  in this chapter is designed so that *one node = one page*: reading a node
  is one I/O, and the cost model of every algorithm is counted in pages
  touched, not comparisons made.
]

#defterm([Fanout])[
  The number of children per internal node — for a page-sized node holding
  keys and child pointers, fanout ≈ `page_size / (key + pointer)` ≈
  hundreds to a thousand. Fanout is the whole game: tree height is
  `log_fanout(rows)`, and height is disk reads per lookup.
]

#tbl(
  (auto, 1fr),
  header: (hcell[Requirement], hcell[Target & reasoning]),
  body: (
    [Lookup depth], [≤ 4 page reads for 10⁹ rows — the height math of Section 8.5 makes this the headline NFR],
    [Write cost], [O(height) page writes per insert, amortized; splits rare at high fanout],
    [Space overhead], [Index ≈ 10–15% of table size; pages 70–90% full on average],
    [Range locality], [Range scans read mostly *sequential* pages — leaves are linked and physically clustered],
    [Cache friendliness], [Top levels of the tree permanently resident in the buffer pool; most lookups hit disk once],
    [Predictable tail latency], [No unbounded rebalancing cascades; split cost is bounded and rare],
  ),
)

Notice that five of the six rows are stated in *page* units, and the sixth
(predictable tail latency) is a page-unit property in disguise — "no
unbounded rebalancing cascades" means "no operation may touch an unbounded
number of pages." This is what it looks like when a system's NFRs are
written in the units of its actual bottleneck. If you find yourself writing
"fast" or "scalable" in this table, you have not yet found the physics;
when the physics is disk I/O, every honest requirement is countable.

#insight([You are designing for the disk, not the data])[
  Every prior chapter counted requests and bytes; this one counts *page
  touches*. A binary search tree does ~30 comparisons for a billion rows —
  and if each node is a random page, ~30 disk reads. A B+ tree does more
  comparisons per node but touches *four* pages. On disk, the "slower" CPU
  structure is 10× faster. The interview is won by whoever counts the right
  resource.
]

== Back-of-the-Envelope: The Physics and the Height Math

Two small tables carry this chapter. The first is the *latency pyramid* —
orders of magnitude worth memorizing, because every storage-engine argument
you will ever have is an argument about where in this pyramid an operation
lands:

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Operation], hcell[Latency], hcell[Consequence]),
  body: (
    [RAM reference], [~100 ns], [The free resource; comparisons are noise],
    [SSD random page read], [~100 µs], [1000× RAM — the unit this chapter minimizes],
    [SSD sequential read], [~10× cheaper per page], [Why leaf links and clustered layout matter],
    [HDD random I/O (seek)], [~10 ms], [100,000× RAM; mechanical arm physics — the original design constraint],
    [Network round trip], [~0.5–1 ms], [For context: why a database page miss still beats a remote call],
  ),
)

Read the pyramid with an eye for *ratios*, and two design rules fall out
before any structure is discussed. Rule one: random vs. sequential is a
10× cliff *on the same device* — so layouts matter as much as algorithms,
which is why "leaves are linked" will turn out to be half the point of the
B+ tree rather than a detail. Rule two: the gap between RAM and *any* disk
touch is three to five orders of magnitude — so a design's disk touches are
its whole cost, and the CPU work between them is, to first order, free.
Structures that look dumb by RAM standards (reading 16 KB to use 100 bytes
of it) are smart by disk standards; this inversion of intuition is the
chapter's entry fee.

*The height derivation* — the most important arithmetic in the chapter,
and the one you should be able to reproduce from an empty whiteboard:

#tbl(
  (auto, auto, 1fr),
  header: (hcell[Quantity], hcell[Value], hcell[Derivation]),
  body: (
    [Page size], [16 KB], [Typical database page],
    [Index entry], [~16 B], [8 B key + 8 B child pointer (interior)],
    [Fanout per page], [~1000], [16 KB / 16 B],
    [Rows reachable, height 2], [~10⁶], [1000 leaf pages × ~1000 entries... precisely: root → 1000 internal pages → leaves; leaves hold 16KB/~(16B+ptr to row) ≈ 500–1000 entries],
    [Rows reachable, height 3], [~10⁹], [A billion rows in *three* levels of internal nodes + leaves],
    [Page reads per lookup], [≤ 4, usually 1–2], [Root and level-1 live in the buffer pool — only the leaf read hits disk],
    [Index size for 10⁹ rows], [~16 GB leaves + ~0.02 GB interior], [Interior levels are negligible — that is why they are always cached],
  ),
)

Do the last row's division out loud, because it is the sneakiest and most
important line in the table. The leaves of a billion-row index cost ~16 GB
— real storage, too big to assume resident. But the *interior* of the tree
— the root plus level 1, every page a lookup might pass through before the
leaf — totals about 20 MB, one eight-hundredth of the leaves. A structure
whose decision-making is three orders of magnitude smaller than its data is
a structure whose decision-making can live in RAM permanently, and *that*
is why "usually 1–2 page reads" is achievable: the cached levels turn
log₁₀₀₀(10⁹) = 3 theoretical reads into one physical one. Caching is not
an optimization bolted onto the B+ tree; the tree's shape is what makes a
tiny cache nearly perfect.

#insight([High fanout collapses height])[
  Binary trees give height log₂ — 30 levels for a billion rows. A fanout of
  1000 gives log₁₀₀₀ — *three*. Since the top two levels are tiny (~16 MB)
  they live in RAM permanently, and a billion-row lookup costs about *one
  disk read*. That is the entire magic trick: not cleverer comparisons,
  just a tree so wide it is nearly flat. Every B-tree property —
  page-sized nodes, separator keys, splits that propagate up rarely —
  exists to protect this fanout.
]

== The Core Challenge: One Structure for Reads *and* Writes

Now the tension can be stated cleanly. Reads want a sorted, dense,
immutable layout — sorted so ranges are contiguous, dense so pages are
full, immutable so nothing ever moves mid-scan. Writes want cheap,
localized mutation — touch as little as possible, as rarely as possible.
Every simple structure you know picks a side, which is why the interview's
"explain exactly why yours beats the alternatives" is really "show me you
know why the alternatives don't work":

#pitfall([The two seductive wrong answers])[
  _Hash index_: O(1) point lookups — and *nothing else*: no ranges, no
  ordering, and rehashing a billion-key table is an outage. It answers the
  question you weren't asked. _Sorted file_: binary search gives O(log n)
  reads and ranges are sequential — but one insert into the middle rewrites
  half the file. Append and it degrades into a log you must compact (that
  idea, pursued seriously, becomes the LSM tree of Section 8.11 — the
  legitimate rival). The B+ tree threads the needle: sorted *and* cheaply
  mutable, because mutation is localized to one page and its ancestors.
]

Notice the careful phrasing of the verdict — not "sorted and mutable," but
"sorted and *cheaply* mutable, because mutation is localized." A sorted
file is also mutable; it just pays for a one-row insert with a half-file
rewrite. The B+ tree's trick is to chop the sorted file into page-sized
pieces and keep a tiny routing hierarchy over the pieces, so that a
mutation's blast radius is one page plus, occasionally, its ancestors. The
sortedness is global (the hierarchy guarantees it), the mutability is local
(the page contains it), and the two stop fighting. Everything else in this
chapter is engineering that protects that truce.

== Candidate Structures

Walk the elimination table as a sequence of *near-misses*, each teaching
one constraint. The hash table's failure is coverage (one read shape out of
three); the sorted file's failure is writes; the plain BST's failure is
balance under real data — and note *which* real data: sorted inserts, the
single most common key pattern in production (auto-increment ids,
timestamps), turn a naive BST into a linked list. The balanced BST is the
instructive loss: it has *all the right complexities* and still loses by
30-to-4 on page touches, which should permanently cure you of evaluating
on-disk structures by comparison counts.

#tbl(
  (1.35fr, 0.75fr, 0.9fr, 0.8fr, 1.6fr),
  header: (hcell[Structure], hcell[Point lookup], hcell[Range scan], hcell[Insert], hcell[Verdict]),
  body: (
    [Hash table], [O(1)], [unsupported], [O(1)], [Point lookups only; no order, no ranges],
    [Sorted array / file], [O(log n)], [O(log n + k)], [O(n)], [Reads fine; a single insert rewrites the file],
    [Binary search tree], [O(n) worst], [O(n)], [O(n) worst], [Unbalanced under real key distributions (sorted inserts!)],
    [Balanced BST (AVL/red-black)], [O(log n)], [O(log n + k)], [O(log n)], [Right complexity, wrong physics: ~30 random pages per lookup],
    [*B+ tree*], [≤4 pages], [≤4 + sequential leaves], [O(height) pages], [Page-sized nodes, fanout ~1000, linked leaves — Section 8.9],
  ),
)

== Deep Dive: B-Tree Mechanics

Here is the structure that survived. Understand it as a set of *invariants*
first and operations second, because every operation is just "do the thing,
then repair the invariants locally":

#defterm([B-tree / node split])[
  A _B-tree_ is a self-balancing search tree where every node is one disk
  page holding up to *m* sorted keys and m+1 child pointers. Invariants:
  all leaves at the same depth; every non-root node at least half full;
  keys sorted within and across nodes. Insertion descends to the target
  leaf; if the leaf overflows, it _splits_ in two and pushes a separator
  key up into the parent — which may itself split, in a bounded cascade
  that, at the root, grows the tree *taller by one level*. Growth by root
  splits is why the tree stays perfectly balanced under any key order —
  including the sorted inserts that destroy naive BSTs.
]

Search is one comparison loop per level: at each internal page, binary
search the separator keys (free — the page is already in RAM by then),
follow the child pointer, read one more page. Height 3–4 (Section 8.5)
⇒ ≤4 page reads, and the upper pages are cached. The picture below is the
chapter's one essential diagram: a fanout-3 toy (production fanout is
~1000, but three fits on paper) with a range scan in progress:

#v(0.3em)
#align(center)[
#canvas(h: 4.9cm)[
  // root
  #node(7.3cm, 0.1cm, 2.4cm, 0.75cm, [35 | 68], fill: faint-teal, edge: teal.darken(10%), size: 8pt)
  // internal level
  #node(2.3cm, 1.7cm, 2.2cm, 0.75cm, [15], fill: faint-teal, edge: teal.darken(10%), size: 8pt)
  #node(7.3cm, 1.7cm, 2.2cm, 0.75cm, [48], fill: white, edge: primary, size: 8pt)
  #node(12.3cm, 1.7cm, 2.2cm, 0.75cm, [80], fill: white, edge: primary, size: 8pt)
  // leaves
  #node(0.3cm, 3.3cm, 2.15cm, 0.75cm, [5 · 8 · 12], fill: faint, edge: slate, size: 7.5pt)
  #node(2.95cm, 3.3cm, 2.15cm, 0.75cm, [15 · 22 · 28], fill: faint-teal, edge: teal.darken(10%), size: 7.5pt)
  #node(5.6cm, 3.3cm, 2.15cm, 0.75cm, [35 · 38 · 44], fill: faint-teal, edge: teal.darken(10%), size: 7.5pt)
  #node(8.25cm, 3.3cm, 2.15cm, 0.75cm, [48 · 55 · 60], fill: faint-teal, edge: teal.darken(10%), size: 7.5pt)
  #node(10.9cm, 3.3cm, 2.15cm, 0.75cm, [68 · 72 · 75], fill: faint, edge: slate, size: 7.5pt)
  #node(13.55cm, 3.3cm, 2.15cm, 0.75cm, [80 · 88 · 95], fill: faint, edge: slate, size: 7.5pt)
  // descent edges
  #arrow(7.9cm, 0.88cm, 3.4cm, 1.65cm, color: teal.darken(10%))
  #arrow(8.5cm, 0.88cm, 8.4cm, 1.65cm, color: slate)
  #arrow(9.3cm, 0.88cm, 13.4cm, 1.65cm, color: slate)
  #arrow(3.0cm, 2.48cm, 1.35cm, 3.25cm, color: slate)
  #arrow(3.9cm, 2.48cm, 4.0cm, 3.25cm, color: teal.darken(10%))
  #arrow(7.9cm, 2.48cm, 6.65cm, 3.25cm, color: slate)
  #arrow(8.9cm, 2.48cm, 9.3cm, 3.25cm, color: slate)
  #arrow(12.9cm, 2.48cm, 11.95cm, 3.25cm, color: slate)
  #arrow(13.9cm, 2.48cm, 14.6cm, 3.25cm, color: slate)
  // leaf links
  #arrow(2.48cm, 3.67cm, 2.92cm, 3.67cm, color: slate, dashed: true)
  #arrow(5.13cm, 3.67cm, 5.57cm, 3.67cm, color: teal.darken(10%), dashed: true)
  #arrow(7.78cm, 3.67cm, 8.22cm, 3.67cm, color: teal.darken(10%), dashed: true)
  #arrow(10.43cm, 3.67cm, 10.87cm, 3.67cm, color: slate, dashed: true)
  #arrow(13.08cm, 3.67cm, 13.52cm, 3.67cm, color: slate, dashed: true)
  // caption
  #glabel(0.3cm, 4.45cm, [Range scan [22, 55]: descend root → internal(15) → leaf 2 (22, 28), then follow leaf links through 55 — never returning upward.], size: 7pt)
]]
#v(0.2em)

Walk the diagram as the range scan `[22, 55]` experiences it, and read the
color as a signal: teal marks everything this query touches, gray everything
it provably skips. Start at the *root*, the teal box `35 | 68` at the top —
two separator keys, three children, and the entire routing logic of the
tree in one rule: keys below 35 go left, 35–68 middle, above 68 right.
The scan's lower bound, 22, is below 35, so the teal arrow descends left to
the internal page `15` — whose single separator splits its subtree at 15,
sending 22 right, into the second leaf. Three pages read (root, internal,
leaf), and the scan has found its *starting point*: leaf `15 · 22 · 28`,
where 22 lives. Everything before this moment is a point lookup for the
range's lower edge — that is all a range scan ever needs from the tree part
of the structure.

Now the second phase, and the reason the leaves are shaded differently from
the internals. From 22 onward, the scan *never goes back up*. It walks
right along the dashed arrows — the *leaf links*: `22, 28` in leaf two,
then leaf three (`35 · 38 · 44`), then leaf four (`48 · 55 · 60`), stopping
the moment it passes 55. Three sequential sideways hops, each almost
certainly a sequential disk read (the pyramid's 10× discount, collected).
Count what the query never touched: the first leaf (5 · 8 · 12 — entirely
below the range, skipped by the descent) and the last two leaves (68+ —
above it, never reached because the walk stopped). The gray arrows and gray
leaves are the structure's promise kept: pages outside the range are not
read, not even once. Now the removal exercise: *delete the dashed links and
ask what breaks.* Every range scan becomes a series of re-descents from the
root — k rows in the range cost k point lookups, the sequential-read
discount vanishes, and `ORDER BY ... LIMIT 20` acquires a sort step it
never needed. The linked-leaf level is not an embellishment; it *is* the
B+ tree's answer to FR-2 and FR-3, and it is why the production variant
(next section) rather than the textbook B-tree is the one that won.

Deletion is the mirror: remove from the leaf; if a node falls below
half-full, borrow from a sibling or merge siblings and pull the separator
down. In practice engines under-fill rather than merge eagerly (merges are
latch-heavy), and a background process rebalances — Section 8.15's "index
bloat" is what happens when even that is neglected. The asymmetry with
insertion is worth naming: inserts split eagerly because an over-full page
is *illegal*; deletes merge lazily because an under-full page is merely
*unfortunate*. Structures tolerate sloppiness in proportion to how much the
sloppiness costs, and a half-empty page costs space, not correctness.

== Deep Dive: The B+ Tree Refinements

The production variant — the B+ tree — differs from the textbook B-tree in
three deliberate ways, and by now you can predict each one from the
physics. Work through them as consequences, not features:

+ *Values live only in leaves.* Internal pages hold pure separator keys —
  no row data — which *increases fanout* (more separators per page) and
  protects the height math. A 16-byte separator routes as well as a 16 KB
  row would; filling interior pages with payloads would buy nothing and
  cost a level. Derivation: interior pages exist to be *read through*, so
  make them maximally thin.
+ *Leaves are linked* in key order (the dashed arrows above). A range scan
  descends once, then walks sideways — sequentially, the disk's favorite
  pattern. This is what makes `ORDER BY ... LIMIT 20` nearly free.
  Derivation: the second and third read shapes must be sequential; sideways
  links are the cheapest way to make leaf N+1 findable from leaf N.
+ *Interior keys are copies.* The separator `35` also exists as a real key
  in a leaf; internal copies are pure routing. Derivation: once values live
  only in leaves, a separator is a *claim* ("everything right of me is ≥
  35") rather than a residence, and claims are cheap to duplicate — which
  is what makes the leaf-level split's copy-up rule (Section 8.13's code
  shows it literally) legal.

Three index *usages* ride on the same structure, and confusing them is the
most common production-indexing mistake — so the vocabulary gets its own
definition block before the trade-off sections lean on it:

#defterm([Clustered / secondary / covering / composite index])[
  A _clustered_ index *is* the table: leaf pages hold full rows, physically
  ordered by the key (one per table; range scans read rows directly). A
  _secondary_ index's leaves hold `(key → primary key)`: a lookup then
  re-descends the clustered index (a "bookmark lookup") — extra I/O per row
  that makes non-covering secondary scans expensive. A _covering_ index
  stores every column the query needs, so the second lookup never happens.
  A _composite_ index keys on `(a, b, c)` as a tuple — usable by queries
  constrained on a *leftmost prefix* (`a`, or `a,b`), useless for `b`
  alone, because the order is lexicographic (Section 8.13 implements the
  rule).
]

The relationships among the four are the mental model to carry: clustered
vs. secondary is about *what the leaf holds* (rows vs. pointers); covering
is a property a secondary index can *earn* by carrying more columns;
composite is about *what the key is* (a tuple), orthogonal to all the rest.
The leftmost-prefix rule follows from lexicographic order alone — a phone
book sorted by (surname, firstname) finds "Smith, John" instantly and
"everyone named John" only by reading every page — and Section 8.13's third
listing reduces the rule to a six-line function, because the rule *is*
six lines; the art is remembering to apply it before creating the index.

== The Write Path: Buffer Pool and WAL

Reads got five sections; writes get this one, because the write path is two
ideas working in tandem, and both are bets on the latency pyramid. Writes
never touch disk directly — instead:

#defterm([Buffer pool])[
  The database's page cache: a fixed RAM arena of page frames with an
  LRU-ish eviction policy. Reads check it first (the tree's top levels are
  effectively pinned by popularity); writes *modify pages in memory* and
  mark them dirty, flushing lazily. Most "database performance" is buffer
  pool hit ratio — Section 8.13 implements the LRU core.
]

#defterm([Write-ahead log (WAL)])[
  The durability trick: before any dirty page may flush, the *intention* —
  an append-only log record of the change — must be durable on disk.
  Appends are sequential and cheap; a crash replays the log to redo
  committed changes. The WAL is what lets the buffer pool defer random page
  writes without losing committed data — the same append-log bet Chapter 1
  made for operations and Chapter 6 made for score journals.
]

See the bet clearly: a committed write performs *one sequential append*
(the WAL record) and zero random writes (the dirty page lingers in the
pool). The random write is not eliminated — it is *deferred and batched*,
flushed later when it can be grouped with neighbors or absorbed by idle
bandwidth. Durability without the deferral is unusably slow (Section 8.16's
table prices it); deferral without durability loses committed data on
crash; the WAL is precisely the bridge that makes deferral safe, because
"the page wasn't flushed" stops meaning "the change was lost" and starts
meaning "the change must be replayed." Crash recovery becomes: read the log
forward, redo committed intentions, done — FR-6 discharged by an append.

The split dance on insert: descend with latches, split the leaf if full,
push the separator up — each split is 2–3 page writes plus a WAL record,
rare at fanout 1000 (a leaf absorbs ~500 inserts between splits), and
amortized into the background flush stream. Do the arithmetic the table
implied: at ~500 inserts per leaf split, a million-row-per-day table splits
leaves a few thousand times daily — each a bounded, local, logged event.
The NFR's "no unbounded rebalancing cascades" is kept not by making splits
impossible but by making them *rare and shallow*: at fanout 1000, a split
propagates to the parent one time in a thousand, and to the grandparent one
time in a million.

== The Rival: LSM Trees

Every "why not" needs its strongest alternative taken seriously, and the
LSM tree is the only one that beats the B+ tree at anything real: *writes*.

#defterm([LSM tree / memtable / SSTable / compaction])[
  The _log-structured merge tree_ is the write-optimized alternative:
  writes land in an in-memory sorted buffer (the _memtable_), which flushes
  periodically to immutable sorted files (the _SSTables_ — Chapter 4's log
  index segments, exactly), and a background process _compacts_ levels by
  merge-sorting them into fewer, bigger files. Reads check the memtable,
  then the newest SSTables outward, with Bloom filters skipping files that
  can't contain the key.
]

Recognize the lineage and you already half-understand the design: the LSM
tree is what happens when you take the *sorted file* — Section 8.6's second
wrong answer — and fix its write problem by never modifying files in place.
Inserts append to memory; memory flushes to a fresh immutable file; files
never change, only multiply and merge. Writes become purely sequential,
which by the pyramid is the cheapest thing a disk can do. The bill arrives
at read time: a point lookup must check the memtable, then potentially
several SSTable generations, with Bloom filters (Chapter 2's bit-array
probabilistic gate, recycled) skipping most of them. The trade, stated as
the table does below, is read amplification for write amplification:

#tbl(
  (1.1fr, 1.5fr, 1.5fr),
  header: (hcell[Property], hcell[B+ tree], hcell[LSM tree]),
  body: (
    [Write path], [Random page updates + splits], [Append + flush: almost purely sequential],
    [Write amplification], [Low-moderate], [Higher: compaction rewrites data repeatedly],
    [Read amplification], [Lowest: ≤4 pages, one structure], [Higher: check memtable + several SSTable levels (Bloom filters help)],
    [Range scans], [Excellent: linked leaves], [Good, but must merge across levels],
    [Space], [Pages 70–90% full], [Compaction leaves transient duplication],
    [Best fit], [Read-heavy OLTP (this chapter's scope)], [Write-heavy logs/time-series (Chapter 4's workload)],
  ),
)

#insight([B+ vs LSM is a read/write *ratio* decision])[
  The two structures dominate modern storage engines, and the choice is not
  fashion: B+ trees minimize read I/O, LSM trees minimize write I/O. State
  the workload's read/write ratio and choose — that sentence, with the
  amplification vocabulary to defend it, is the entire "which storage
  engine" follow-up.
]

Look back at the scope dialogue and notice you were told the answer: "mixed;
neither extreme. Reads dominate slightly" is B+ tree territory, and Chapter
4's append-mostly telemetry was LSM territory — which is why the book's two
storage-deep chapters land on opposite structures without contradicting
each other. When the interviewer asks "so which is better?", the senior
answer is a question: "what's the ratio?"

== The Storage Engine's Interface

The structure above serves a deliberately small API — five operations —
and this is what the rest of the database (and Chapter 5's and 6's tables)
stand on. Notice that the interface says nothing about trees, pages, or
splits: to the layers above, an index is a sorted map with cursors. The
physics leaks upward only through *performance characteristics*, never
through semantics — a separation worth copying in your own systems.

#tbl(
  (auto, 1fr),
  header: (hcell[Operation], hcell[Semantics]),
  body: (
    [`get(key)`], [Point lookup → row or location; ≤4 page reads],
    [`scan(lo, hi)` / cursor], [Ordered range iteration; the cursor holds a page + position — Chapter 5's cursor at the storage layer],
    [`insert(key, row)`], [Descend, insert in leaf, split as needed, WAL first],
    [`delete(key)`], [Remove from leaf; underflow handled lazily],
    [`create index (cols)`], [Build a secondary B+ tree by scanning the table once, sorting, and bulk-loading leaves left-to-right (far cheaper than n inserts)],
  ),
)

The last row hides a lovely optimization worth naming in the room:
*bulk-loading*. Building an index by n individual inserts pays n descents,
~n/500 splits, and produces pages in random physical order. Building it by
sorting the keys once and writing leaves left-to-right pays one sort and
produces a perfectly packed, physically sequential tree — the difference
between an afternoon and a coffee break on a billion-row table. When a
structure knows its own invariants, creating it wholesale is always cheaper
than growing it retail; that is as true for Chapter 9's replicated state as
it is here.

== Rust Reference Implementations

Four pieces with deterministic tests: the B+ tree itself (split logic and
all), a sparse-index page lookup (the SSTable trick from Section 8.11),
the leftmost-prefix rule (six lines that decide whether your composite
index exists in vain), and the LRU buffer pool. The tree is the centerpiece
— read it as the invariants from Section 8.8 made executable.

=== A B+ Tree with Splits

The implementation compresses the whole mechanics section into two mutually
recursive ideas. *Descent* (`get`, and the internal arm of `insert_rec`)
uses `partition_point` over the separator keys — the same "first separator
greater than the key bounds the descent from the left" rule you traced on
the diagram. *Overflow repair* returns a `Split` value upward: a leaf that
exceeds `MAX_KEYS` divides at the middle and reports `Split { sep, right }`,
where the B+ *copy-up* rule is visible in one comment — `sep` is the right
half's first key, and it *stays in the leaf too*, because leaves hold all
real keys and interiors hold mere claims. The internal split, by contrast,
*pushes* the middle key up with `keys.pop()` — interiors route, so their
middle key is promoted, not copied. Copy-up in leaves, push-up in
interiors: that asymmetry, which textbooks state in prose, is here two
lines you can point at. `ORDER` is deliberately tiny (4) so the tests
exercise dozens of splits on a hundred keys — the invariant-checking
`check` function then verifies what the rush of splits must preserve: keys
sorted everywhere, children = keys + 1 everywhere, and every leaf at the
*same depth*, which is the "perfectly balanced under any key order" promise
from the definition, asserted rather than assumed.

```rust
const ORDER: usize = 4; // max children per node — tiny so tests exercise splits
const MAX_KEYS: usize = ORDER - 1;

#[derive(Debug, Clone)]
enum Node {
    Leaf { keys: Vec<u64>, vals: Vec<u64> },
    Internal { keys: Vec<u64>, children: Vec<Node> }, // keys[i] = min key of children[i+1]
}

pub struct BPlusTree {
    root: Node,
}

enum Split {
    None,
    Split { sep: u64, right: Node },
}

impl BPlusTree {
    pub fn new() -> Self {
        BPlusTree { root: Node::Leaf { keys: vec![], vals: vec![] } }
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        let mut node = &self.root;
        loop {
            match node {
                Node::Leaf { keys, vals } => {
                    return keys.binary_search(&key).ok().map(|i| vals[i]);
                }
                Node::Internal { keys, children } => {
                    // first separator > key bounds the descent from the left
                    let i = keys.partition_point(|&k| key >= k);
                    node = &children[i];
                }
            }
        }
    }

    pub fn insert(&mut self, key: u64, val: u64) {
        if let Split::Split { sep, right } = insert_rec(&mut self.root, key, val) {
            let old = std::mem::replace(
                &mut self.root,
                Node::Leaf { keys: vec![], vals: vec![] },
            );
            self.root = Node::Internal { keys: vec![sep], children: vec![old, right] };
        }
    }

    /// Ordered [lo, hi] scan — in production this descends once and walks
    /// linked leaves; here we prune recursively, same result set.
    pub fn range(&self, lo: u64, hi: u64) -> Vec<(u64, u64)> {
        let mut out = Vec::new();
        collect_range(&self.root, lo, hi, &mut out);
        out
    }

    pub fn height(&self) -> usize {
        let (mut h, mut node) = (1, &self.root);
        while let Node::Internal { children, .. } = node {
            node = &children[0];
            h += 1;
        }
        h
    }
}

fn insert_rec(node: &mut Node, key: u64, val: u64) -> Split {
    match node {
        Node::Leaf { keys, vals } => {
            let pos = keys.partition_point(|&k| k < key);
            if pos < keys.len() && keys[pos] == key {
                vals[pos] = val; // upsert: no duplicate keys
                return Split::None;
            }
            keys.insert(pos, key);
            vals.insert(pos, val);
            if keys.len() <= MAX_KEYS { return Split::None; }
            let mid = keys.len() / 2;
            let rkeys = keys.split_off(mid);
            let rvals = vals.split_off(mid);
            let sep = rkeys[0]; // B+ copy-up: the key stays in the leaf too
            Split::Split { sep, right: Node::Leaf { keys: rkeys, vals: rvals } }
        }
        Node::Internal { keys, children } => {
            let i = keys.partition_point(|&k| key >= k);
            match insert_rec(&mut children[i], key, val) {
                Split::None => Split::None,
                Split::Split { sep, right } => {
                    keys.insert(i, sep);
                    children.insert(i + 1, right);
                    if keys.len() <= MAX_KEYS { return Split::None; }
                    let mid = keys.len() / 2;
                    let up = keys[mid];
                    let rkeys = keys.split_off(mid + 1);
                    keys.pop(); // internal split pushes the middle UP, no copy
                    let rchildren = children.split_off(mid + 1);
                    Split::Split {
                        sep: up,
                        right: Node::Internal { keys: rkeys, children: rchildren },
                    }
                }
            }
        }
    }
}

fn collect_range(node: &Node, lo: u64, hi: u64, out: &mut Vec<(u64, u64)>) {
    match node {
        Node::Leaf { keys, vals } => {
            for (i, &k) in keys.iter().enumerate() {
                if k >= lo && k <= hi {
                    out.push((k, vals[i]));
                }
            }
        }
        Node::Internal { keys, children } => {
            for (i, child) in children.iter().enumerate() {
                let lower = if i == 0 { 0 } else { keys[i - 1] };
                let upper = if i == keys.len() { u64::MAX } else { keys[i] };
                if hi >= lower && lo <= upper {
                    collect_range(child, lo, hi, out);
                }
            }
        }
    }
}

#[cfg(test)]
mod btree_tests {
    use super::*;

    fn check(node: &Node, depth: usize, leaf_depths: &mut Vec<usize>) {
        match node {
            Node::Leaf { keys, .. } => {
                assert!(keys.windows(2).all(|w| w[0] < w[1]));
                leaf_depths.push(depth);
            }
            Node::Internal { keys, children } => {
                assert_eq!(keys.len() + 1, children.len());
                assert!(keys.windows(2).all(|w| w[0] < w[1]));
                assert!(keys.len() <= MAX_KEYS);
                for c in children {
                    check(c, depth + 1, leaf_depths);
                }
            }
        }
    }

    #[test]
    fn insert_search_range_stay_consistent() {
        let mut t = BPlusTree::new();
        let mut keys: Vec<u64> = (0..100).collect();
        keys.sort_by_key(|&k| (k * 37) % 101); // deterministic shuffle
        for &k in &keys {
            t.insert(k, k * 10);
        }
        for k in 0..100u64 {
            assert_eq!(t.get(k), Some(k * 10));
        }
        assert_eq!(t.get(100), None);
        let r = t.range(25, 42);
        assert_eq!(r.len(), 18);
        assert_eq!(r.first().unwrap().0, 25);
        assert_eq!(r.last().unwrap().0, 42);
        assert!(r.windows(2).all(|w| w[0].0 < w[1].0));
        let mut depths = Vec::new();
        check(&t.root, 1, &mut depths);
        assert!(depths.iter().all(|&d| d == depths[0])); // perfectly balanced
        assert!(t.height() <= 6, "height {}", t.height());
    }

    #[test]
    fn upsert_overwrites_without_duplication() {
        let mut t = BPlusTree::new();
        t.insert(5, 50);
        t.insert(5, 500);
        assert_eq!(t.get(5), Some(500));
        assert_eq!(t.range(0, 1000).len(), 1);
    }
}
```

The main test is worth reading as three arguments in sequence. First,
*correctness under shuffled load*: a deterministic scramble of 0–99 is
inserted, and every key reads back — the split machinery surviving a
hundred insertions in adversarial (non-sorted) order. Second, *range
semantics*: `range(25, 42)` returns exactly 18 ordered pairs, endpoints
inclusive, order ascending — the FR-2 promise with witnesses. Third, the
*invariant audit*: the recursive `check` walks the whole tree asserting
sortedness and arity at every node, collects every leaf's depth, and
demands they all agree. That last assertion is the one a naive BST fails
catastrophically and this structure cannot fail at all — growth happens
only at the root (see `insert`: when the root splits, a brand-new internal
root is built *above* the old one), so all leaves deepen together or not at
all. "The tree grows taller from the top" is the sentence; the test is its
proof.

=== Sparse-Index Page Lookup

The second listing is the LSM world's answer to "how do you find a key in
an immutable sorted file without an index that costs as much as the file?"
— and it is the same fanout idea from Section 8.5 wearing plainer clothes.
Keep one *sample* per block of keys in memory (the block's first key and
where the block starts); a lookup binary-searches the tiny sample array,
then searches exactly one block. The memory cost drops from O(n) to
O(n/SPAN), and the lookup cost stays at two searches, the second over a
handful of entries. When Section 8.11 said "Bloom filters skip files that
can't contain the key," this structure is what does the finding in the
files that can.

```rust
/// A sorted run of keys with an in-memory sparse index: one sample per
/// SPAN keys (the LSM/SSTable trick — binary search the samples, then
/// search one tiny block; a full index would cost O(n) memory).
pub struct SparseIndex {
    keys: Vec<u64>,
    sample: Vec<(u64, usize)>, // (first key of block, block start index)
}

impl SparseIndex {
    const SPAN: usize = 4;

    pub fn new(mut keys: Vec<u64>) -> Self {
        keys.sort();
        let sample = keys
            .iter()
            .enumerate()
            .step_by(Self::SPAN)
            .map(|(i, &k)| (k, i))
            .collect();
        SparseIndex { keys, sample }
    }

    pub fn find(&self, key: u64) -> Option<usize> {
        if self.keys.is_empty() { return None; }
        // last sample whose key <= key
        let idx = self.sample.partition_point(|&(k, _)| k <= key);
        if idx == 0 { return None; } // key precedes the first sample
        let start = self.sample[idx - 1].1;
        let end = (start + Self::SPAN).min(self.keys.len());
        self.keys[start..end]
            .binary_search(&key)
            .ok()
            .map(|off| start + off)
    }
}

#[cfg(test)]
mod sparse_tests {
    use super::*;

    #[test]
    fn finds_via_sample_then_block() {
        let idx = SparseIndex::new((0..40).map(|i| i * 3).collect());
        assert_eq!(idx.find(27), Some(9));   // 27 = 9*3
        assert_eq!(idx.find(0), Some(0));    // first sample boundary
        assert_eq!(idx.find(117), Some(39)); // last block
        assert_eq!(idx.find(118), None);     // past the end
        assert_eq!(idx.find(1), None);       // inside a block, absent
    }
}
```

Read the test as a tour of the boundary conditions, because sparse
structures fail at edges, not middles. `find(0)` must not fall off the
front of the sample array (the `idx == 0` guard is what makes "before the
first sample" a clean miss rather than a panic — note it also means keys
*before* the first sample cannot exist, because the first sample is the
first key). `find(117)` exercises the final, possibly short block; `find(1)`
is the interesting miss: 1 would sort into block 0 but is not in it, so the
block search returns absent — a sparse index narrows the search, it never
*decides* presence. That two-phase honesty (samples locate, blocks decide)
is exactly how Chapter 9's replicated logs and Chapter 4's segment indexes
use the same trick.

=== The Leftmost-Prefix Rule

The third listing is the smallest in the chapter and might save you the
most grief in practice. Section 8.9 defined the rule in prose — a composite
index `(a, b, c)` serves queries constrained on a leading run of its
columns — and here it is as a function: walk the index columns from the
left, count how many have equality constraints, and stop at the first gap.
Six lines, and yet mis-indexing against this rule is among the most common
causes of "the database ignored my index" in production (Section 8.18's
first follow-up). The rule exists because lexicographic order can only
*seek* on a contiguous prefix: after the first unconstrained column, later
columns are no longer sorted in any way the query can exploit — exactly
like the phone book that can find "Smith, J..." but not "...John".

```rust
/// How many leading columns of a composite index `(a, b, c)` a query can
/// use for equality lookups: the longest run of index columns that all
/// have equality constraints. After the prefix, at most one range column
/// remains usable — columns past it are unreachable by the index order.
pub fn usable_prefix(index_cols: &[&str], equality_cols: &[&str]) -> usize {
    index_cols
        .iter()
        .take_while(|c| equality_cols.contains(c))
        .count()
}

#[cfg(test)]
mod prefix_tests {
    use super::*;

    #[test]
    fn lexicographic_order_decides_usability() {
        let idx = ["a", "b", "c"];
        assert_eq!(usable_prefix(&idx, &["a", "b"]), 2); // a, b usable
        assert_eq!(usable_prefix(&idx, &["b"]), 0);      // b alone: useless
        assert_eq!(usable_prefix(&idx, &["a", "c"]), 1); // a only; c skipped over b
        assert_eq!(usable_prefix(&idx, &["a", "b", "c"]), 3);
        assert_eq!(usable_prefix(&idx, &[]), 0);
    }
}
```

The third assertion is the one to remember in the room: a query
constraining `a` and `c` uses *only* `a` — the gap at `b` ends the usable
prefix, and `c`'s constraint becomes a post-filter over whatever the
`a`-scan returns. When you design the composite index for a query (the
wrap-up's second follow-up makes you), order its columns so that the
query's equalities form an unbroken left run; that single decision is most
of what "index design" means in practice.

=== The Buffer Pool (LRU)

The last listing is the write path's other half: the page cache from
Section 8.10, here as a minimal LRU — a hash map for O(1) page lookup plus
a recency deque, front-most-recent. The doc comment carries two honest
caveats worth saying aloud. First, `touch` is O(n) for clarity; production
uses an intrusive linked list for O(1). Second — and this is the systems
point — plain LRU has a famous pathology, *scan pollution*: one full table
scan marches every page of the table through the pool, evicting the hot set
to make room for pages that will never be read again. Real engines use
LRU-K or clock variants precisely to resist it (Section 8.15's thrashing
row is that pathology with symptoms attached). Recency is a proxy for
reuse; scans are the workload that breaks the proxy.

```rust
use std::collections::{HashMap, VecDeque};

/// Page cache with LRU eviction. O(n) recency refresh for clarity;
/// production uses an intrusive linked list for O(1) touches (and often
/// LRU-K or clock variants to resist scan pollution).
pub struct BufferPool {
    cap: usize,
    frames: HashMap<u64, Vec<u8>>, // page id -> contents
    recency: VecDeque<u64>,        // front = most recently used
}

impl BufferPool {
    pub fn new(cap: usize) -> Self {
        BufferPool { cap, frames: HashMap::new(), recency: VecDeque::new() }
    }

    pub fn get(&mut self, page: u64) -> Option<&[u8]> {
        if self.frames.contains_key(&page) {
            self.touch(page);
            return self.frames.get(&page).map(Vec::as_slice);
        }
        None
    }

    pub fn put(&mut self, page: u64, data: Vec<u8>) {
        if self.frames.contains_key(&page) {
            self.frames.insert(page, data);
            self.touch(page);
            return;
        }
        if self.frames.len() == self.cap {
            let victim = self.recency.pop_back().expect("pool nonempty");
            self.frames.remove(&victim);
        }
        self.frames.insert(page, data);
        self.touch(page);
    }

    fn touch(&mut self, page: u64) {
        self.recency.retain(|&p| p != page);
        self.recency.push_front(page);
    }
}

#[cfg(test)]
mod pool_tests {
    use super::*;

    #[test]
    fn lru_evicts_least_recently_used() {
        let mut bp = BufferPool::new(2);
        bp.put(1, b"a".to_vec());
        bp.put(2, b"b".to_vec());
        assert!(bp.get(1).is_some()); // refresh page 1 -> page 2 is now LRU
        bp.put(3, b"c".to_vec());     // evicts page 2
        assert!(bp.get(2).is_none());
        assert_eq!(bp.get(1).unwrap(), b"a");
        assert_eq!(bp.get(3).unwrap(), b"c");
    }

    #[test]
    fn overwrite_refreshes_recency() {
        let mut bp = BufferPool::new(2);
        bp.put(1, b"a".to_vec());
        bp.put(2, b"b".to_vec());
        bp.put(1, b"a2".to_vec()); // refresh via overwrite
        bp.put(3, b"c".to_vec());  // evicts page 2, not page 1
        assert_eq!(bp.get(1).unwrap(), b"a2");
        assert!(bp.get(2).is_none());
    }
}
```

The two tests pin the two ways a page earns survival: being *read*
(`lru_evicts_least_recently_used` — the `get(1)` between the puts is what
dooms page 2) and being *rewritten* (`overwrite_refreshes_recency` — a
`put` on a resident page also refreshes it, because a write is a use).
Together they encode the policy statement precisely: every access, read or
write, renews the lease. When Section 8.17 names buffer-pool hit ratio the
database's vital sign, these fourteen lines of policy are the heart whose
rhythm is being measured.

== Scaling the Structure

A structure chapter's scaling section reads differently from a product
chapter's: the axes are properties of the *data* (rows, key size,
distribution) rather than of the traffic, and the "what breaks first"
column is where the operational wisdom lives.

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Axis], hcell[How the B+ tree scales], hcell[What breaks first]),
  body: (
    [Rows], [Height grows as log₁₀₀₀ — billions stay at depth 3–4], [Nothing, structurally; table *breadth* (columns × row size) pressures page economics first],
    [Read concurrency], [Buffer pool serves cached levels; leaf reads parallelize across I/O], [Buffer pool hit ratio — watch it fall as the working set outgrows RAM],
    [Write rate], [Splits amortized at fanout ~1000; WAL absorbs burstiness], [Random-page flush bandwidth; past it, the workload is telling you LSM],
    [Key size], [Fanout = page/entry — fat keys flatten it], [Oversized keys (long strings) cut fanout and deepen the tree; hash or prefix-compress them],
    [Distribution], [The index shards with its table (Chapter 5)], [Hot partitions get hot index pages — the tree scales, the shard doesn't],
  ),
)

Two rows reward a slow reading. *Rows* — the axis you'd expect to dominate
— breaks *nothing structurally*: that is the log₁₀₀₀ height doing its job,
and the first real pressure comes from table breadth instead, because wider
rows mean fewer entries per leaf page and the fanout arithmetic quietly
degrades. The tree's enemy is never row *count*; it is entry *size*. And
*write rate* names the exact crossover to the rival: as long as random-page
flush bandwidth absorbs the dirty-page stream, the B+ tree wins; the moment
it doesn't, "the workload is telling you LSM" — the failure mode is the
signal, and Section 8.11's table is the translation.

== Failure Modes & Degradation

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Failure], hcell[Symptom], hcell[Response]),
  body: (
    [Crash mid-split], [Torn or half-written pages], [WAL replay redoes committed work; page checksums detect torn writes; never corrupt *silently*],
    [Buffer pool thrashing], [Latency spike; hit ratio collapses], [A scan read the whole table through the pool — LRU variants (LRU-K, clock) resist scan pollution; pin critical levels],
    [Index bloat], [Pages half-empty after mass deletes; scans slow], [Lazy underfill + background rebalancing/rebuild; monitor fill factor],
    [Write burst], [Split cascades on a hot range], [Sequential keys (auto-increment, timestamps) concentrate inserts on the rightmost leaf — the *rightmost hotspot*; hash-prefix or reverse the key],
    [Corrupted page], [Checksum mismatch on read], [Fail the query loudly, rebuild from replica/WAL; an index is derived state — it can always be rebuilt from the table],
    [Runaway query], [Optimizer ignores the index, full-scans], [Section 8.18: selectivity, stale statistics; `ANALYZE`, or force the index — then fix the statistics],
  ),
)

Read the first row and the fifth together: they are the chapter's integrity
stance. A torn page is acceptable; a *silently* torn page is not — checksums
convert "wrong bytes that look fine" into "a loud error that triggers
repair," and the repair is always available because an index is *derived
state*: the table is the truth, the index a rebuildable projection (Chapter
6's journal philosophy at the storage layer). The *rightmost hotspot* row
deserves a story: an auto-increment key means every insert targets the
maximum key, hence the rightmost leaf, hence *one page* — so a structure
designed to spread a billion keys across a million pages serializes the
whole write load through a single 16 KB page's latch. The fixes
(hash-prefixing, key reversal, ULIDs) all do the same thing: trade a
little key readability to restore the insert spread the structure assumed.

== Trade-offs & Alternatives

#tbl(
  (auto, 1fr, 1fr),
  header: (hcell[Decision], hcell[Chosen], hcell[Alternative & why not (here)]),
  body: (
    [Core structure], [B+ tree, page-sized nodes], [Hash index: no ranges; sorted file: no cheap writes; balanced BST: 30 random I/Os vs 4 (Section 8.7)],
    [Values in leaves only], [B+ variant], [Classic B-tree stores values in internal nodes too — fatter interior, lower fanout, and it breaks the leaf-link range trick],
    [Write-heavy alternative], [LSM tree when writes dominate], [Chosen blindly: read amplification and compaction stalls bite read-heavy workloads],
    [Durability], [WAL + lazy page flush], [Flush pages synchronously per commit: correct and unusably slow],
    [Underflow handling], [Lazy (underfill, rebalance later)], [Eager merge on every delete: latch contention and churn for negligible space],
    [Sequential keys], [Accept rightmost hotspot or hash-prefix], [Ignore it: one leaf page serializes the entire insert rate],
    [Index everything], [No — indexes are write tax], [Each index is paid on every insert; cover the queries you have, not the queries you fear],
  ),
)

The last row is the table's conscience and the working engineer's most-used
row. Every index is a subscription the writes pay for: insert one row into
a table with six secondary indexes and you perform seven ordered-structure
inserts, seven WAL records, seven sets of split risk. "Cover the queries
you have, not the queries you fear" is therefore not stinginess but
accounting — an index justified by an imaginary query is a certain cost
weighed against an imaginary benefit, and those always lose. When the
feared query materializes, `CREATE INDEX` (Section 8.12's bulk-load row)
builds the structure in one scan; the tax starts only when the benefit
does.

== Observability & SLOs

#tbl(
  (auto, 1fr, auto),
  header: (hcell[Indicator], hcell[Definition], hcell[Target]),
  body: (
    [Buffer pool hit ratio], [Reads served from RAM / all page reads], [≥ 99% for hot indexes],
    [Pages per query], [Page touches per lookup/scan], [≤4 point; ≈ k/page-fill for ranges],
    [Write amplification], [Bytes written / bytes inserted], [Low single digits for B+ trees],
    [Fill factor], [Average page occupancy], [70–90%; alert on sustained decline],
    [Slow query count], [Queries past the latency SLO, from the slow log], [Flat; investigate every step up],
    [Split rate], [Page splits per second], [Proportional to inserts; spikes signal hotspots],
  ),
)

Each row is a section of the chapter rendered as a gauge: hit ratio is
Section 8.10, pages per query is Section 8.5's height math with a target
attached, fill factor watches Section 8.15's bloat, split rate watches the
rightmost hotspot. If you can only add one, add the hit ratio — it is the
vital sign all the others explain. A database whose hit ratio falls from
99% to 95% has not gotten 4% slower; it has quadrupled its disk traffic,
and the latency distribution will say so in the tail long before the mean
admits anything.

== Interview Wrap-Up

Likely follow-ups, and the shape of strong answers:

+ *"Why didn't the database use my index?"* Selectivity: if the predicate
  matches 30% of the table, a scan is *cheaper* than 300M random bookmark
  lookups — the optimizer is right, and understanding *why* it is right
  (random I/O per row vs. sequential I/O per page) is the answer's core.
  Secondary causes: stale statistics, a function wrapped around the column
  (`WHERE LOWER(email) = ?` defeats the index on `email`), or a composite
  index whose leftmost prefix the query doesn't constrain (Section 8.13's
  rule).
+ *"Design the index for this query"* — `WHERE tenant_id = ? AND
  created > ? ORDER BY created LIMIT 20`: composite `(tenant_id, created)`
  — equality on the leftmost column, range + order on the second; the sort
  is free and the LIMIT reads ~one page. This one composite index is the
  single most common production index shape; know it cold, and narrate it
  through the chapter's machinery — the equality pins the scan to one
  tenant's contiguous key-slice, the range rides the slice's internal
  order, and the LIMIT stops the leaf-walk after twenty rows.
+ *"B-tree vs hash for a key-value store?"* Hash for pure point gets at
  extreme write volume (and the LSM if writes dominate); B+ the moment
  ranges, ordering, or prefix scans appear. Memcached vs. the world.
+ *"How do transactions fit in?"* Isolation layers above the structure:
  latches protect pages physically; locks/MVCC protect transactions
  logically. The B+ tree doesn't change; version chains or lock tables
  hang off it. Mentioning the latch/lock distinction unprompted is a depth
  signal — Chapter 11 picks up exactly here.
+ *"Why do UUID primary keys hurt?"* Random keys destroy insert locality —
  every insert lands on a random leaf, defeating the buffer pool — and
  bloat every secondary index that references them. Time-ordered UUIDs
  (ULID/UUIDv7) exist precisely to give keys back their locality: the
  rightmost hotspot's mirror image, where the fix is not to spread writes
  but to *restore the order* the structure prefers.

== Summary & Further Reading

#notebox([Chapter summary])[
  The B+ tree is not a data structure choice; it is *disk physics made
  flesh*. Random I/O is 10⁵× slower than RAM, so the structure minimizes
  page touches: page-sized nodes give fanout ~1000, which collapses a
  billion rows into height 3–4, of which the top levels live in the buffer
  pool — one disk read per lookup. Splits keep it balanced under any key
  order; values-in-leaves and linked leaves make range scans sequential;
  the WAL buys durability with appends instead of random flushes. The LSM
  tree is the mirror-image choice when writes dominate. Indexes are a bet
  paid on every write and collected on every read — composite, covering,
  and leftmost-prefix design decide whether the bet pays. Chapters 5 and 6
  stood on this chapter; this chapter is why they could.
]

*Further reading.*

- The source video: _"How do B-Tree Indexes work? — Systems Design
  Interview: 0 to 1 with Google Software Engineer"_ (Jordan has no life):
  `https://www.youtube.com/watch?v=Z2OaqmxiH20`
- CMU 15-445 (Andy Pavlo's database course, lectures + notes) — buffer
  pools, B+ trees, and latching in production depth.
- Hellerstein, Stonebraker, Hamilton — _Architecture of a Database System_
  (2007) — the map of everything around the index.
- O'Neil et al. — _"The Log-Structured Merge-Tree"_ (1996) — the rival, in
  its own words.
- SQLite's file-format documentation — a complete, readable B-tree
  implementation spec you can finish in an evening.

== Chapter Glossary

#tbl(
  (auto, 1fr),
  header: (hcell[Term], hcell[Meaning]),
  body: (
    [B-tree], [Self-balancing multiway search tree; node = page, fanout high, all leaves level],
    [B+ tree], [B-tree with values only in leaves, linked leaves, separator-only interiors; the production variant],
    [Bookmark lookup], [The second descent from a secondary index's leaf into the clustered index to fetch the row],
    [Buffer pool], [The page cache between the tree and disk; hit ratio is the database's vital sign],
    [Clustered index], [An index whose leaves hold full rows — the table itself, ordered by the key],
    [Compaction], [LSM background merge of SSTables into fewer levels; reclaims space, restores read shape],
    [Composite index], [Index on a tuple of columns; usable by leftmost prefix only],
    [Covering index], [An index storing every column a query needs — no bookmark lookup],
    [Fanout], [Children per node; page size / entry size; the number that collapses tree height],
    [Fill factor], [Average page occupancy; declines with deletes into index bloat],
    [Latch vs. lock], [Latch: physical, short-term page protection; lock: logical, transaction-scope protection],
    [Leftmost-prefix rule], [A composite index serves only queries constraining a leading run of its columns],
    [LSM tree], [Log-structured merge tree: memtable + immutable SSTables + compaction; write-optimized],
    [Memtable], [The LSM's in-memory sorted write buffer, flushed to SSTables],
    [Order / MAX\_KEYS], [Max children per node (order m); max keys m−1; overflow triggers splits],
    [Page], [The fixed-size I/O and buffer-pool unit (4–16 KB); one node per page],
    [Range scan], [Ordered retrieval of [lo, hi]; one descent plus linked-leaf walk],
    [Rightmost hotspot], [Sequential keys concentrating all inserts on one leaf page, serializing writes],
    [Secondary index], [Index whose leaves map key → primary key, not full rows],
    [Selectivity], [Fraction of rows a predicate matches; low selectivity makes the optimizer choose a scan — correctly],
    [Separator key], [Interior routing key = minimum key of the right child; a copy in B+ trees],
    [Sparse index], [One sample per block over a sorted run; binary search samples, then the block — SSTable lookup],
    [Split], [Node overflow → two nodes + separator pushed up; root split grows the tree a level],
    [SSTable], [Sorted String Table: immutable sorted file flushed from a memtable; Chapter 4's segments],
    [WAL], [Write-ahead log: durable append of intentions before any page flush; crash = replay],
  ),
)

#v(0.8em)
#align(center)[
  #text(size: 8.5pt, fill: slate)[
    — End of Chapter 8 · Next: Chapter 9, Designing Conflict-Free Replication: How CRDTs Work —
  ]
]
