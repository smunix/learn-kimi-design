// ============================================================================
//  THE SYSTEM DESIGN INTERVIEW PLAYBOOK
//  Author: Providence Salumu  ·  Typeset with Typst  ·  Code samples in Rust
// ============================================================================
#import "template.typ": *

#set document(
  title: "The System Design Interview Playbook",
  author: "Providence Salumu",
  keywords: ("system design", "interviews", "distributed systems", "google docs", "real-time collaboration", "google maps", "geospatial", "routing", "traffic", "rate limiting", "api gateway", "observability", "logging", "metrics", "comments", "ranking", "voting", "leaderboard", "top-k", "skip list", "recommendation", "machine learning", "feed", "b-tree", "database", "index", "crdt", "replication", "consistency", "vector clock"),
  date: datetime(year: 2026, month: 9, day: 5),
)

#show: conf

// ============================================================================
//  COVER PAGE
// ============================================================================
#page(margin: 0cm, background: rect(width: 100%, height: 100%, fill: ink))[
  // decorative rings, right side
  #place(top + right, dx: 2.6cm, dy: 7.2cm, circle(radius: 4.6cm, stroke: 9pt + ink-soft.lighten(12%), fill: none))
  #place(top + right, dx: 6.2cm, dy: 10.6cm, circle(radius: 1.05cm, stroke: 5pt + teal, fill: none))
  #place(top + right, dx: 9.1cm, dy: 4.3cm, circle(radius: 0.42cm, fill: primary))
  #place(bottom + left, dx: -2.2cm, dy: -2.0cm, circle(radius: 3.4cm, stroke: 7pt + ink-soft.lighten(8%), fill: none))

  #pad(left: 2.3cm, right: 2.3cm, top: 4.9cm)[
    #rect(width: 2.4cm, height: 5pt, fill: teal)
    #v(0.9cm)
    #text(font: ("Noto Sans", "DejaVu Sans"), size: 9.5pt, weight: "semibold",
          fill: teal.lighten(18%), tracking: 0.32em)[SYSTEM DESIGN INTERVIEW SERIES · VOLUME I]
    #v(0.85cm)
    #text(font: ("Noto Sans", "DejaVu Sans"), size: 37pt, weight: "black", fill: white)[
      The System Design \ Interview Playbook
    ]
    #v(0.85cm)
    #text(font: ("Noto Serif", "DejaVu Serif"), size: 11.5pt, style: "italic", fill: rgb("#B9C1DC"))[
      A growing compendium of real interview problems, solved end-to-end:
      rigorous definitions, back-of-the-envelope mathematics, protocol design,
      and production-grade Rust implementations.
    ]
    #v(1.5cm)
    #block(fill: rgb("#222A52"), radius: 7pt, inset: (x: 14pt, y: 11pt))[
      #text(font: ("Noto Sans", "DejaVu Sans"), size: 8.2pt, weight: "bold",
            fill: teal.lighten(18%), tracking: 0.18em)[IN THIS VOLUME]
      #v(5pt)
      #text(font: ("Noto Sans", "DejaVu Sans"), size: 10.5pt, fill: white)[
        Chapter 01 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Real-Time Collaborative Text Editor (Google Docs / Notion)

        Chapter 02 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Maps & Navigation Service (Google Maps)

        Chapter 03 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Distributed Rate Limiter

        Chapter 04 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Distributed Logging & Metrics Platform

        Chapter 05 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Hierarchical Comment System (Reddit)

        Chapter 06 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Top-K Leaderboard (Gaming)

        Chapter 07 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Recommendation Engine (YouTube / TikTok)

        Chapter 08 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing a Database Index — How B-Trees Work

        Chapter 09 #h(4pt) #text(fill: rgb("#8E98C0"))[—] #h(4pt)
        Designing Conflict-Free Replication — How CRDTs Work
      ]
    ]
    #v(1fr)
  ]
  #place(bottom + left, dx: 2.3cm, dy: -2.1cm)[
    #text(font: ("Noto Sans", "DejaVu Sans"), size: 13pt, weight: "bold", fill: white)[Providence Salumu]
    #v(3pt)
    #text(font: ("Noto Sans", "DejaVu Sans"), size: 8.4pt, fill: rgb("#8E98C0"))[
      First Edition · September 2026 · A living document — chapters are added incrementally
    ]
  ]
]

// ============================================================================
//  IMPRINT PAGE
// ============================================================================
#v(1fr)
#align(center)[
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 12pt, weight: "bold", fill: ink)[
    The System Design Interview Playbook
  ]
  #v(4pt)
  #text(size: 9pt, fill: slate)[Volume I · First Edition]
  #v(14pt)
  #text(size: 9pt)[
    Written and typeset by *Providence Salumu* \
    Composed in Typst · Body set in Noto Serif · Display set in Noto Sans · Code set in Noto Sans Mono
  ]
  #v(14pt)
  #block(width: 78%, inset: 10pt, stroke: (top: 0.6pt + code-edge, bottom: 0.6pt + code-edge))[
    #text(font: ("Noto Sans", "DejaVu Sans"), size: 7.8pt, weight: "bold", fill: slate, tracking: 0.12em)[REVISION HISTORY]
    #v(4pt)
    #text(size: 8.6pt)[
      #table(
        columns: (auto, 1fr, auto),
        stroke: none, inset: (x: 6pt, y: 3.5pt),
        [*v0.1*], [Chapter 1 — Real-Time Collaborative Text Editor], [2026-09-05],
        [*v0.2*], [Chapter 2 — Maps & Navigation Service (Google Maps)], [2026-09-05],
        [*v0.3*], [Chapter 3 — Distributed Rate Limiter], [2026-09-05],
        [*v0.4*], [Chapter 4 — Distributed Logging & Metrics Platform], [2026-09-05],
        [*v0.5*], [Chapter 5 — Hierarchical Comment System (Reddit)], [2026-09-05],
        [*v0.6*], [Chapter 6 — Top-K Leaderboard (Gaming)], [2026-09-05],
        [*v0.7*], [Chapter 7 — Recommendation Engine (YouTube / TikTok)], [2026-09-05],
        [*v0.8*], [Chapter 8 — Database Indexes: How B-Trees Work], [2026-09-05],
        [*v0.9*], [Chapter 9 — Conflict-Free Replication: How CRDTs Work], [2026-09-06],
      )
    ]
  ]
  #v(14pt)
  #text(size: 8pt, fill: slate)[
    © 2026 Providence Salumu. This document grows chapter by chapter; \
    each chapter is a self-contained walkthrough of one interview problem.
  ]
]
#v(2cm)

#hide-deco.update(false)
#counter(page).update(1)

// ============================================================================
//  TABLE OF CONTENTS
// ============================================================================
#pagebreak()
#block(above: 1.6em, below: 1.1em)[
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 21pt, weight: "black", fill: ink)[Contents]
  #v(6pt)
  #rect(width: 2.4cm, height: 2.6pt, fill: teal, radius: 2pt)
]
#show outline.entry.where(level: 1): it => {
  v(1.0em)
  text(font: ("Noto Sans", "DejaVu Sans"), size: 10.5pt, weight: "bold", fill: ink, it)
}
#show outline.entry.where(level: 2): it => {
  v(0.35em)
  text(size: 9.3pt, it)
}
#outline(title: none, indent: 1.6em, depth: 2)

// ============================================================================
//  PREFACE
// ============================================================================
#heading(level: 1, numbering: none)[Preface]

This book exists because system design interviews reward a very specific skill that
ordinary engineering work rarely exercises in full: _taking an ambiguous, enormous
problem and shrinking it, in real time and out loud, into a coherent, defensible
architecture._ Knowing how Netflix or Google Docs works is not enough; you must be
able to *derive* such a design from first principles while an interviewer watches
you think.

#defterm([System design interview])[
  An interview format, common for senior engineering roles, in which the candidate
  is asked to design a large-scale software system (for example, "design YouTube"
  or "design a URL shortener") within 45–60 minutes. There is no single correct
  answer. The interviewer evaluates how you clarify ambiguity, structure the
  problem, justify trade-offs, and reason about scale, failure, and consistency.
]

Each chapter of this book is a complete, self-contained walkthrough of one such
problem. Every chapter follows the same battle-tested structure, which mirrors the
natural arc of a strong interview performance:

#block(fill: faint, radius: 6pt, inset: (x: 14pt, y: 10pt), width: 100%)[
  #set text(size: 9.2pt)
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold", fill: slate, tracking: 0.1em)[THE CHAPTER FRAMEWORK]
  #v(4pt)
  + *Problem statement* — the prompt exactly as an interviewer would pose it.
  + *Clarifying questions & scope* — shrinking an ambiguous prompt into a concrete target.
  + *Functional requirements* — what the system must _do_.
  + *Non-functional requirements* — how _well_ it must do it (scale, latency, availability).
  + *Back-of-the-envelope estimation* — arithmetic that sizes the problem before designing.
  + *The core challenge* — the one or two genuinely hard ideas this problem tests.
  + *API & protocol design* — the contract between clients and servers.
  + *Data model & storage* — what we persist, where, and why.
  + *High-level architecture* — the boxes and the arrows, with every box justified.
  + *Deep dives* — the mechanisms, including complete Rust reference implementations.
  + *Trade-offs & alternatives* — what we gave up, and what we would do differently.
  + *Wrap-up* — likely follow-up questions, common pitfalls, and an interview checklist.
]

#heading(level: 2, numbering: none)[Conventions used in this book]

Three conventions deserve explicit mention.

_Terms are defined before they are used._ System design is full of overloaded
vocabulary — "consistency", "snapshot", "version vector" — and interviews are lost
when a candidate uses a term they cannot define. Whenever a new concept appears,
it is introduced in a *Definition* box before the surrounding text relies on it.

_All code is written in Rust._ Rust's explicit ownership and type system make
concurrency logic — the hardest part of most designs — precise and auditable. The
listings are not toys: they are faithful, compilable sketches of the real
algorithms, with tests.

_Numbers are always justified._ Every estimate states its assumptions. A number
without assumptions is decoration; a number with assumptions is engineering.

#heading(level: 2, numbering: none)[How this book grows]

This is a living document. New chapters are appended over time, each tackling one
new problem. The framework above is fixed, so you always know where to find the
requirements, the math, the architecture, and the code — regardless of the problem.

#v(0.4em)
#align(right)[
  #text(style: "italic", size: 9.5pt)[Providence Salumu — September 2026]
]

// ============================================================================
//  CHAPTERS
// ============================================================================
#include "chapters/chapter-01.typ"
#include "chapters/chapter-02.typ"
#include "chapters/chapter-03.typ"
#include "chapters/chapter-04.typ"
#include "chapters/chapter-05.typ"
#include "chapters/chapter-06.typ"
#include "chapters/chapter-07.typ"
#include "chapters/chapter-08.typ"
#include "chapters/chapter-09.typ"
