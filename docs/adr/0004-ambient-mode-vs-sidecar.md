# ADR-0004: Ambient mode vs Sidecar mode

## Status

Accepted

## Context

OpenShift Service Mesh 3 supports two data plane models:

- **Sidecar mode**: Each pod has an additional injected Envoy container that intercepts all traffic. Classic Istio model.
- **Ambient mode**: Uses a ztunnel DaemonSet per node (L4) and optional waypoint proxies per namespace (L7). No sidecars.

Ambient mode reached General Availability (GA) in SM3 3.2. This PoC aims to explore the most modern service mesh capabilities.

## Options Considered

### Option 1: Ambient mode -- chosen
- **Pros:** No sidecars (lower CPU/memory per pod). Incremental adoption (L4 by default, optional L7 with waypoint). No pod restart required to enroll in the mesh. Zero-trust security model with mTLS always active in ztunnel. GA since SM3 3.2.
- **Cons:** Requires `routingViaHost: true` (ADR-0002). Newer architecture with less third-party documentation. ztunnel has a concurrency limitation that may affect throughput in extreme scenarios.

### Option 2: Sidecar mode
- **Pros:** Mature model with extensive documentation. Does not require OVN changes. More troubleshooting tools available.
- **Cons:** Sidecar per pod (memory overhead ~50-100MB per proxy). Requires pod restart to inject sidecar. More complex to operate at scale.

## Decision

Use ambient mode for this PoC. It is the model recommended by Red Hat for new deployments and demonstrates the most modern Istio architecture with lower operational overhead.

## Consequences

### Positive
- Lower resource consumption: one ztunnel per node instead of one sidecar per pod.
- Enrolling/unenrolling workloads in the mesh is instant (namespace label, no restart).
- Automatic mTLS between all enrolled workloads without additional configuration.
- L7 features opt-in via waypoint proxy only where needed.

### Negative
- Requires the OVN patch `routingViaHost: true` (ADR-0002).
- VirtualService is Technology Preview in ambient (ADR-0005); only Gateway API is supported.
- Less community documentation compared to sidecar mode.

### Neutral
- Observability mechanisms (Kiali, Prometheus, Tempo) work with both modes.
- AuthorizationPolicies require a dual enforcement model (ADR-0008).

## References

- [Blog: Introducing SM3 3.2 with Istio ambient mode](https://www.redhat.com/en/blog/introducing-openshift-service-mesh-32-istios-ambient-mode): "general availability of Istio's ambient mode"
- [SM3 3.3 Installing - Ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)
- [SM3 3.2 Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html-single/release_notes/index): sec. 1.5.1 "General availability of Istio ambient mode"
