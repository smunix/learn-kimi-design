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
  chapters, this is a *fundamentals* deep dive — the interviewer asks you to
  design the index structure of a relational database's storage engine:
  something that answers point lookups and range scans in milliseconds over
  billions of rows, survives a write-heavy workload, and lives on hardware
  whose physics you must respect. It is also the keystone chapter: Chapters
  5 and 6 stored data in "the database"; this chapter designs what they were
  standing on. All terms are defined before use; all reference code is Rust
  with deterministic tests.
]

== The Problem Statement

The interviewer draws a table with a billion rows and says:

_"Queries filter on equality (`email = ?`) and on ranges with ordering
(`created BETWEEN ? AND ?`, `ORDER BY created`). The table lives on disk.
Design the index structure that makes those fast — and explain exactly why
yours beats the alternatives."_

This is a design problem with an unusually well-defined physics: the
bottleneck is not CPU or capacity but *disk I/O shape* — every random read
costs ~10⁵ times a memory reference, so the entire game is minimizing the
number of disk pages touched per operation. The B+ tree won this game fifty
years ago; the interview tests whether you can re-derive *why* from first
principles, not whether you can recite it.

#defterm([Index])[
  A redundant, derived data structure that maps a search key to the location
  of full rows, maintained by the database on every write. An index trades
  write cost and space for read speed: every `INSERT` pays to keep it
  current, and every matching query repays that cost a thousandfold. "Adding
  an index" is never free — it is a bet that reads outnumber writes.
]

#defterm([Point lookup / range scan / sorted iteration])[
  The three read shapes an index can serve: _point lookup_ (`key = ?`),
  _range scan_ (`lo ≤ key ≤ hi`), and _sorted iteration_ (`ORDER BY key`
  without a sort step). A structure that serves all three is dramatically
  more valuable than one serving only the first — this asymmetry eliminates
  the hash index from the running almost immediately (Section 8.7).
]

== Scope & Clarifying Questions

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

#notebox([Agreed scope])[
  + Design the on-disk index structure for a single-node relational storage
    engine: *point lookup*, *range scan*, *sorted iteration*, *insert*,
    *delete*.
  + Respect disk physics: I/O in fixed-size pages; random I/O is the scarce
    resource.
  + Cover the write path (buffer pool, WAL, splits) and the B+ tree's
    classic variants (clustered, secondary, covering, composite).
  + Position the LSM tree as the write-optimized alternative and know when
    it wins.
  + Out: concurrency control protocols, distributed indexes, query
    optimization beyond index selection basics.
]

== Functional Requirements

+ *FR-1 — Point lookup.* `key → row location` in a small, bounded number of
  page reads regardless of table size.
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

== Non-Functional Requirements

#defterm([Page / block I/O])[
  Disks do not read bytes; they read *pages* — fixed-size blocks (4–16 KB)
  that are the atomic unit of I/O and of the buffer pool. Every structure in
  this chapter is designed so that *one node = one page*: reading a node is
  one I/O, and the cost model of every algorithm is counted in pages
  touched, not comparisons made.
]

#defterm([Fanout])[
  The number of children per internal node — for a page-sized node holding
  keys and child pointers, fanout ≈ `page_size / (key + pointer)` ≈ hundreds
  to a thousand. Fanout is the whole game: tree height is `log_fanout(rows)`,
  and height is disk reads per lookup.
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

#insight([You are designing for the disk, not the data])[
  Every prior chapter counted requests and bytes; this one counts *page
  touches*. A binary search tree does ~30 comparisons for a billion rows —
  and if each node is a random page, ~30 disk reads. A B+ tree does more
  comparisons per node but touches *four* pages. On disk, the "slower" CPU
  structure is 10× faster. The interview is won by whoever counts the right
  resource.
]

== Back-of-the-Envelope: The Physics and the Height Math

*Latency pyramid* (orders of magnitude — memorize these):

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

*The height derivation* — the most important arithmetic in the chapter:

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

#insight([High fanout collapses height])[
  Binary trees give height log₂ — 30 levels for a billion rows. A fanout of
  1000 gives log₁₀₀₀ — *three*. Since the top two levels are tiny (~16 MB)
  they live in RAM permanently, and a billion-row lookup costs about *one
  disk read*. That is the entire magic trick: not cleverer comparisons, just
  a tree so wide it is nearly flat. Every B-tree property — page-sized
  nodes, separator keys, splits that propagate up rarely — exists to protect
  this fanout.
]

== The Core Challenge: One Structure for Reads *and* Writes

The tension: reads want sorted, dense, immutable layouts; writes want cheap,
localized mutation. Structures that ace one side fail the other:

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

== Candidate Structures

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

#defterm([B-tree / node split])[
  A _B-tree_ is a self-balancing search tree where every node is one disk
  page holding up to *m* sorted keys and m+1 child pointers. Invariants: all
  leaves at the same depth; every non-root node at least half full; keys
  sorted within and across nodes. Insertion descends to the target leaf; if
  the leaf overflows, it _splits_ in two and pushes a separator key up into
  the parent — which may itself split, in a bounded cascade that, at the
  root, grows the tree *taller by one level*. Growth by root splits is why
  the tree stays perfectly balanced under any key order — including the
  sorted inserts that destroy naive BSTs.
]

Search is one comparison loop per level: at each internal page, binary
search the separator keys, follow the child pointer, read one more page.
Height 3–4 (Section 8.5) ⇒ ≤4 page reads, and the upper pages are cached.

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

Deletion is the mirror: remove from the leaf; if a node falls below
half-full, borrow from a sibling or merge siblings and pull the separator
down. In practice engines under-fill rather than merge eagerly (merges are
latch-heavy), and a background process rebalances — Section 8.15's "index
bloat" is what happens when even that is neglected.

== Deep Dive: The B+ Tree Refinements

The production variant differs from the textbook B-tree in three deliberate
ways:

+ *Values live only in leaves.* Internal pages hold pure separator keys —
  no row data — which *increases fanout* (more separators per page) and
  protects the height math.
+ *Leaves are linked* in key order (the dashed arrows above). A range scan
  descends once, then walks sideways — sequentially, the disk's favorite
  pattern. This is what makes `ORDER BY ... LIMIT 20` nearly free.
+ *Interior keys are copies.* The separator `35` also exists as a real key
  in a leaf; internal copies are pure routing.

Three index *usages* ride on the same structure:

#defterm([Clustered / secondary / covering / composite index])[
  A _clustered_ index *is* the table: leaf pages hold full rows, physically
  ordered by the key (one per table; range scans read rows directly). A
  _secondary_ index's leaves hold `(key → primary key)`: a lookup then
  re-descends the clustered index (a "bookmark lookup") — extra I/O per row
  that makes non-covering secondary scans expensive. A _covering_ index
  stores every column the query needs, so the second lookup never happens.
  A _composite_ index keys on `(a, b, c)` as a tuple — usable by queries
  constrained on a *leftmost prefix* (`a`, or `a,b`), useless for `b` alone,
  because the order is lexicographic (Section 8.13 implements the rule).
]

== The Write Path: Buffer Pool and WAL

Writes never touch disk directly:

#defterm([Buffer pool])[
  The database's page cache: a fixed RAM arena of page frames with an LRU-ish
  eviction policy. Reads check it first (the tree's top levels are
  effectively pinned by popularity); writes *modify pages in memory* and
  mark them dirty, flushing lazily. Most "database performance" is buffer
  pool hit ratio — Section 8.13 implements the LRU core.
]

#defterm([Write-ahead log (WAL)])[
  The durability trick: before any dirty page may flush, the *intention* —
  an append-only log record of the change — must be durable on disk. Appends
  are sequential and cheap; a crash replays the log to redo committed
  changes. The WAL is what lets the buffer pool defer random page writes
  without losing committed data — the same append-log bet Chapter 1 made
  for operations and Chapter 6 made for score journals.
]

The split dance on insert: descend with latches, split the leaf if full,
push the separator up — each split is 2–3 page writes plus a WAL record,
rare at fanout 1000 (a leaf absorbs ~500 inserts between splits), and
amortized into the background flush stream.

== The Rival: LSM Trees

#defterm([LSM tree / memtable / SSTable / compaction])[
  The _log-structured merge tree_ is the write-optimized alternative: writes
  land in an in-memory sorted buffer (the _memtable_), which flushes
  periodically to immutable sorted files (the _SSTables_ — Chapter 4's log
  index segments, exactly), and a background process _compacts_ levels by
  merge-sorting them into fewer, bigger files. Reads check the memtable,
  then the newest SSTables outward, with Bloom filters skipping files that
  can't contain the key.
]

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
  amplification vocabulary to defend it, is the entire "which storage engine"
  follow-up.
]

== The Storage Engine's Interface

The structure above serves a deliberately small API — this is what the rest
of the database (and Chapter 5's and 6's tables) stand on:

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

== Rust Reference Implementations

Four pieces with deterministic tests: the B+ tree itself, a sparse-index
page lookup, the leftmost-prefix rule, and the LRU buffer pool.

=== A B+ Tree with Splits

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

=== Sparse-Index Page Lookup

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

=== The Leftmost-Prefix Rule

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

=== The Buffer Pool (LRU)

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

== Scaling the Structure

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

== Interview Wrap-Up

Likely follow-ups and the shape of strong answers:

+ *"Why didn't the database use my index?"* Selectivity: if the predicate
  matches 30% of the table, a scan is *cheaper* than 300M random bookmark
  lookups — the optimizer is right. Secondary causes: stale statistics, a
  function wrapped around the column (`WHERE LOWER(email) = ?` defeats the
  index on `email`), or a composite index whose leftmost prefix the query
  doesn't constrain (Section 8.13's rule).
+ *"Design the index for this query"* — `WHERE tenant_id = ? AND
  created > ? ORDER BY created LIMIT 20`: composite `(tenant_id, created)` —
  equality on the leftmost column, range + order on the second; the sort is
  free and the LIMIT reads ~one page. This one composite index is the single
  most common production index shape; know it cold.
+ *"B-tree vs hash for a key-value store?"* Hash for pure point gets at
  extreme write volume (and the LSM if writes dominate); B+ the moment
  ranges, ordering, or prefix scans appear. Memcached vs the world.
+ *"How do transactions fit in?"* Isolation layers above the structure:
  latches protect pages physically; locks/MVCC protect transactions
  logically. The B+ tree doesn't change; version chains or lock tables hang
  off it. Mentioning the latch/lock distinction is a depth signal.
+ *"Why do UUID primary keys hurt?"* Random keys destroy insert locality —
  every insert lands on a random leaf, defeating the buffer pool — and bloat
  every secondary index that references them. Time-ordered UUIDs (ULID/UUIDv7)
  exist precisely to give keys back their locality.

== Summary & Further Reading

#notebox([Chapter summary])[
  The B+ tree is not a data structure choice; it is *disk physics made
  flesh*. Random I/O is 10⁵× slower than RAM, so the structure minimizes
  page touches: page-sized nodes give fanout ~1000, which collapses a
  billion rows into height 3–4, of which the top levels live in the buffer
  pool — one disk read per lookup. Splits keep it balanced under any key
  order; values-in-leaves and linked leaves make range scans sequential; the
  WAL buys durability with appends instead of random flushes. The LSM tree
  is the mirror-image choice when writes dominate. Indexes are a bet paid on
  every write and collected on every read — composite, covering, and
  leftmost-prefix design decide whether the bet pays. Chapters 5 and 6 stood
  on this chapter; this chapter is why they could.
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
    — End of Chapter 8 · Next: Chapter 9 —
  ]
]
