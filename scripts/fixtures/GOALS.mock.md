# Goals: mock walk fixture
_Not a real feature. Used by mock-walk.sh._

```yaml
plan: PLAN.md
log: PLAN-REVIEW-LOG.md
journal: docs/journal/mock.md
goals:
  - id: g1-alpha
    title: First slice
    blocked_by: []
    conflicts_with: []
    area: mock/a
    proof: true
    oracle: inline
    status: ready
  - id: g2-beta
    title: Second slice
    blocked_by: [g1-alpha]
    conflicts_with: []
    area: mock/b
    proof: true
    oracle: inline
    status: blocked
  - id: g3-gamma
    title: Third slice
    blocked_by: [g2-beta]
    conflicts_with: []
    area: mock/c
    proof: true
    oracle: inline
    status: blocked
  - id: g4-delta
    title: Fourth slice
    blocked_by: [g3-gamma]
    conflicts_with: []
    area: mock/d
    proof: true
    oracle: inline
    status: blocked
```
