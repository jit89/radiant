# Goals: example fixture

Used by `install.sh --check` and `scripts/goals.py` tests. Not a real
feature.

```yaml
plan: PLAN.md
log: PLAN-REVIEW-LOG.md
journal: docs/journal/example.md
goals:
  - id: g1-store
    title: Persist inbound mail
    blocked_by: []
    conflicts_with: []
    area: mailer/inbound
    proof: true
    oracle: inline
    status: ready
  - id: g2-ack
    title: Label-ack after enqueue
    blocked_by: [g1-store]
    conflicts_with: []
    area: mailer/inbound
    proof: true
    oracle: inline
    status: blocked
  - id: g3-other
    title: Independent sibling
    blocked_by: []
    conflicts_with: [g1-store]
    area: mailer/outbound
    proof: true
    oracle: inline
    status: ready
```
