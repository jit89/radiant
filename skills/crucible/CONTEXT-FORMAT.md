# CONTEXT.md — glossary format

`CONTEXT.md` is a glossary and nothing else: the project's chosen
words, one definition each. No implementation details, no specs, no
scratch notes.

## Shape

```md
# {Project or Context Name}

{One sentence: what this context covers.}

## Terms

**Deal**
One negotiated agreement with one sponsor, containing its deliverables.
Not: "campaign", "contract", "engagement"

**Milestone**
A payment checkpoint on a deal with an amount and a due date.
Not: "invoice", "installment"
```

## Rules

- One canonical term per concept; competing synonyms go on the `Not:`
  line so the ban is explicit.
- A definition is one or two sentences stating what the thing *is*.
  Behavior belongs in code or the plan, not here.
- Admit only domain terms. Anything a programmer would recognize from
  any other project (retry, handler, cache) stays out.
- Flat list until clusters genuinely emerge; then subheadings.
- Create the file only when the first term is actually settled.

## Repos with more than one domain

Signal with a root `CONTEXT-MAP.md` that lists each context, its
folder, and how they talk (events consumed, shared identifiers). Each
context keeps its own `CONTEXT.md`.

Resolution: `CONTEXT-MAP.md` present → pick the context matching the
current work (ask if ambiguous); root `CONTEXT.md` only → single
context; neither → create a root `CONTEXT.md` lazily.
