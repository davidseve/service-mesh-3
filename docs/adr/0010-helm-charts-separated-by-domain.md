# ADR-0010: Helm charts separated by domain

## Status

Accepted

## Context

All PoC infrastructure needs to be packaged with Helm. There are two main approaches:
- A single umbrella chart grouping everything as dependencies.
- Independent charts separated by functional domain.

Resources have clear temporal dependencies: operators must be ready before the control plane, the control plane before apps, etc.

## Options Considered

### Option 1: Independent charts by domain (chosen)
- **Pros:** Incremental deployment (each domain can be installed/updated separately). Easy troubleshooting (isolated failure per chart). Makefile orchestrates order. Reusability (operators chart can be reused).
- **Cons:** Multiple `helm upgrade` commands instead of one.

### Option 2: Single umbrella chart
- **Pros:** One `helm upgrade` deploys everything.
- **Cons:** Does not support temporal dependencies (cannot wait for operators to be ready before creating CRs). Failure in one template blocks everything. Harder to debug.

## Decision

Separate into 6 charts by functional domain:

```
charts/
  operators/        -> OLM Subscriptions
  control-plane/    -> Istio, IstioCNI, ZTunnel CRs
  apps/             -> Deployments, Services, ConfigMaps
  gateway-routing/  -> Gateways, HTTPRoutes, Waypoint, OCP Route
  security/         -> AuthorizationPolicies (ALLOW + DENY anti-bypass)
  observability/    -> Kiali CR, TempoStack, OTEL Collector
```

The `Makefile` orchestrates the sequence with targets that include waits between phases.

## Consequences

### Positive
- Each chart can be installed, updated, and debugged independently.
- The Makefile manages temporal dependencies (wait-operators, wait-mesh).
- Facilitates learning: each chart can be studied separately.

### Negative
- More helm commands to deploy everything (mitigated by the Makefile).

### Neutral
- The number of charts is fixed and predictable for this PoC.

## References

- Project decision (no Red Hat documentation reference required).
