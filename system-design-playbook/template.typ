// ============================================================================
//  THE SYSTEM DESIGN INTERVIEW PLAYBOOK
//  A living compendium of system design interview problems, solved end-to-end.
//  Author: Providence Salumu
//  Typeset with Typst. Code samples in Rust.
// ============================================================================

#let ink        = rgb("#1A2141")  // deep navy — headings, cover
#let ink-soft   = rgb("#232A4D")  // secondary navy
#let primary    = rgb("#3457D5")  // royal blue — accents
#let teal       = rgb("#0E9F9F")  // teal — definitions, accents
#let amber      = rgb("#B97A14")  // dark amber — tips
#let crimson    = rgb("#C2413B")  // brick red — pitfalls
#let slate      = rgb("#5A6172")  // muted text
#let faint      = rgb("#EEF1F8")  // light fill
#let faint-teal = rgb("#E7F5F5")
#let faint-amber= rgb("#FBF3E4")
#let faint-red  = rgb("#FBEDEC")
#let faint-blue = rgb("#ECF0FD")
#let code-bg    = rgb("#F7F8FB")
#let code-edge  = rgb("#DFE3EE")


// ---------------------------------------------------------------------------
//  DOCUMENT-WIDE STYLE — applied via #show: conf in main.typ
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
//  RUNNING DECORATIONS STATE
// ---------------------------------------------------------------------------
#let hide-deco = state("hide-deco", true)

#let running-header = context {
  if hide-deco.get() { none } else {
    let pg = here().page()
    let openers = query(heading.where(level: 1))
    let on-opener = openers.find(h => h.location().page() == pg) != none
    if on-opener { none } else {
      let past = query(selector(heading.where(level: 1)).before(here()))
      let title = if past.len() > 0 { past.last().body } else { [] }
      set text(font: ("Noto Sans", "DejaVu Sans"), size: 7.8pt, fill: slate)
      grid(
        columns: (1fr, auto),
        smallcaps(title), [The System Design Interview Playbook],
      )
      v(-2pt)
      line(length: 100%, stroke: 0.5pt + code-edge)
    }
  }
}

#let running-footer = context {
  if hide-deco.get() { none } else {
    set text(font: ("Noto Sans", "DejaVu Sans"), size: 8.2pt, fill: slate)
    align(center)[— #counter(page).display("1") —]
  }
}


// ---------------------------------------------------------------------------
//  CHAPTER OPENER
// ---------------------------------------------------------------------------
#let chapter-opener(kicker, num, title) = {
  pagebreak(weak: true)
  if num != none {
    place(top + right, dx: 0.15cm, dy: -1.15cm,
      text(font: ("Noto Sans", "DejaVu Sans"), size: 118pt, weight: "black", fill: faint)[#num])
  }
  v(1.15cm)
  text(font: ("Noto Sans", "DejaVu Sans"), size: 9.5pt, weight: "semibold",
       fill: teal, tracking: 0.28em)[#kicker]
  v(0.30cm)
  text(font: ("Noto Sans", "DejaVu Sans"), size: 25pt, weight: "black", fill: ink, title)
  v(0.30cm)
  rect(width: 3.1cm, height: 3.2pt, fill: teal, radius: 2pt)
  v(0.85cm)
}



#let conf(doc) = {
set text(font: ("Noto Serif", "DejaVu Serif"), size: 10pt, lang: "en")
set par(justify: true, leading: 0.68em, spacing: 1.15em)
show link: set text(fill: primary)
set list(indent: 10pt, marker: ([#text(fill: primary)[•]], [#text(fill: primary)[–]]))
set enum(indent: 10pt)

show raw.where(block: true): it => block(
  fill: code-bg,
  stroke: 0.6pt + code-edge,
  radius: 5pt,
  inset: (x: 11pt, y: 9pt),
  width: 100%,
  above: 1.1em,
  below: 1.1em,
  text(font: ("Noto Sans Mono", "DejaVu Sans Mono"), size: 8.2pt, it),
)
show raw.where(block: false): it => box(
  fill: faint,
  inset: (x: 3.5pt, y: 0pt),
  outset: (y: 2.6pt),
  radius: 3pt,
  text(font: ("Noto Sans Mono", "DejaVu Sans Mono"), size: 8.4pt, it),
)

set page(
  paper: "a4",
  margin: (top: 2.5cm, bottom: 2.4cm, x: 2.1cm),
  header: running-header,
  footer: running-footer,
)

set heading(numbering: "1.1")

show heading.where(level: 1): it => {
  if it.numbering == none {
    chapter-opener([FRONT MATTER], none, it.body)
  } else {
    let n = counter(heading).display("1")
    chapter-opener([CHAPTER #n], n, it.body)
  }
}

show heading.where(level: 2): it => {
  v(0.55em)
  block(below: 0.75em)[
    #text(font: ("Noto Sans", "DejaVu Sans"), size: 13.5pt, weight: "bold", fill: ink)[
      #box(baseline: 12%, rect(width: 5.5pt, height: 13.5pt, fill: primary, radius: 1.5pt))
      #h(7pt)
      #if it.numbering != none [#counter(heading).display("1.1")#h(9pt)]
      #it.body
    ]
  ]
}

show heading.where(level: 3): it => block(above: 1.3em, below: 0.6em)[
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 11pt, weight: "bold", fill: primary.darken(12%))[
    #if it.numbering != none [#counter(heading).display("1.1.1")#h(7pt)]
    #it.body
  ]
]


  doc
}


// ---------------------------------------------------------------------------
//  CALLOUT BOXES
// ---------------------------------------------------------------------------
#let callout(label, title, body, accent, bg) = block(
  fill: bg,
  stroke: (left: 2.6pt + accent),
  radius: (top-right: 6pt, bottom-right: 6pt),
  inset: (x: 12pt, y: 9pt),
  width: 100%,
  above: 1.1em,
  below: 1.1em,
)[
  #text(font: ("Noto Sans", "DejaVu Sans"), size: 8pt, weight: "bold",
        fill: accent.darken(8%), tracking: 0.09em)[#label — #title]
  #v(2.5pt)
  #text(size: 9.4pt)[#body]
]

#let defterm(term, body)   = callout([DEFINITION], term, body, teal, faint-teal)
#let insight(title, body)  = callout([KEY INSIGHT], title, body, primary, faint-blue)
#let tip(title, body)      = callout([INTERVIEW TIP], title, body, amber, faint-amber)
#let pitfall(title, body)  = callout([COMMON PITFALL], title, body, crimson, faint-red)
#let notebox(title, body)  = callout([NOTE], title, body, slate, faint)

// ---------------------------------------------------------------------------
//  TABLES
// ---------------------------------------------------------------------------
#let hcell(body) = table.cell(
  text(font: ("Noto Sans", "DejaVu Sans"), size: 8.4pt, weight: "bold", fill: white)[#body])

#let tbl(widths, header: (), body: ()) = table(
  columns: widths,
  inset: (x: 8pt, y: 6.5pt),
  stroke: (x, y) => (
    left: none, right: none,
    top: if y == 0 { none } else { 0.55pt + code-edge },
    bottom: if y == 0 { none } else { 0.55pt + code-edge },
  ),
  fill: (x, y) => if y == 0 { ink } else if calc.odd(y) { faint } else { white },
  table.header(..header),
  ..body,
)

// ---------------------------------------------------------------------------
//  DIAGRAM PRIMITIVES  (nodes + arrows placed in a fixed-size canvas)
// ---------------------------------------------------------------------------
#let canvas(w: 100%, h: 6cm, body) = box(width: w, height: h, clip: true, body)

#let node(x, y, w, h, label, fill: white, edge: primary, fg: ink, size: 8pt, weight: "bold", radius: 5pt) = place(dx: x, dy: y,
    rect(width: w, height: h, fill: fill, stroke: 0.9pt + edge, radius: radius)[
      #align(center + horizon,
        text(font: ("Noto Sans", "DejaVu Sans"), size: size, weight: weight, fill: fg, label))
    ])

#let glabel(x, y, body, fg: slate, size: 7.4pt) = place(dx: x, dy: y, text(font: ("Noto Sans", "DejaVu Sans"), size: size, fill: fg, body))

#let arrow(x1, y1, x2, y2, color: slate, thick: 0.9pt, dashed: false, head-size: 5.5pt) = {
  let dx = (x2 - x1).pt()
  let dy = (y2 - y1).pt()
  let len = calc.sqrt(dx * dx + dy * dy)
  let ang = calc.atan2(dx, dy)
  let dash = if dashed { "dashed" } else { "solid" }
  place(dx: x1, dy: y1, line(angle: ang, length: len * 1pt, stroke: (paint: color, thickness: thick, dash: dash)))
  // arrowhead: two wings
  let w1 = ang + 150deg
  let w2 = ang - 150deg
  place(dx: x2, dy: y2, line(angle: w1, length: head-size, stroke: thick + color))
  place(dx: x2, dy: y2, line(angle: w2, length: head-size, stroke: thick + color))
}

#let lifeline(x, y-top, y-bottom, color: code-edge) = place(dx: x, dy: y-top,
  line(angle: 90deg, length: (y-bottom - y-top), stroke: (paint: color, thickness: 0.8pt, dash: "dashed")))

