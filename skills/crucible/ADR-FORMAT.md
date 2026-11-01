# ADR format

Architecture Decision Records live in `docs/adr/`, numbered
sequentially (`0001-slug.md` …). Create the directory the first time
an ADR is actually written; next number = highest existing + 1.

## Template

```md
# {Decision, stated as a fact}

{A short paragraph: the situation, what was decided, and the reason.}
```

A paragraph is a complete ADR. Extra sections only when they earn it:

- `status:` frontmatter (`proposed` / `accepted` / `deprecated` /
  `superseded-by: 0007`) — when decisions get revisited
- **Alternatives** — when the losing options will be re-proposed
- **Consequences** — when a downstream effect is non-obvious

## The three-part test (all three)

1. **Reversal is expensive.** Cheap-to-undo choices don't need records.
2. **A future reader would be puzzled.** If the code makes the choice
   self-evident, the record is redundant.
3. **A genuine trade-off was made.** "We did the only sensible thing"
   records nothing.

## What typically passes

- Structural commitments: repo layout, event-sourcing vs CRUD,
  monolith vs services.
- How contexts communicate; who owns which data.
- Lock-in technology picks — the quarter-to-replace ones, not every
  library.
- Deliberate departures from the path a reasonable engineer would
  assume.
- Invisible constraints the code can't show.
- Non-obvious rejections — the alternative someone will suggest again.
