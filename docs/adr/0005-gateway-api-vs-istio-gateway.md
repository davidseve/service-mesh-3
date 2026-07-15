# ADR-0005: Gateway API vs Istio Gateway/VirtualService

## Status

Accepted

## Context

In Istio there are two sets of APIs for managing ingress traffic and routing:

- **Istio APIs**: `Gateway` (networking.istio.io) and `VirtualService`. Original Istio APIs, mature and widely documented.
- **Kubernetes Gateway API**: `Gateway` (gateway.networking.k8s.io) and `HTTPRoute`. Native Kubernetes API, standardized by SIG-Network.

In SM3 ambient mode, Red Hat classifies VirtualService as **Technology Preview (TP)**. The documentation states explicitly: "you should not mix them with Gateway API configuration. The recommended approach in ambient mode is to use Kubernetes Gateway API resources."

OCP 4.19+ includes Gateway API CRDs by default (supported by Red Hat).

## Options Considered

### Option 1: Kubernetes Gateway API (chosen)
- **Pros:** Only fully supported API in ambient mode. Native Kubernetes (portability). Required to configure waypoint proxies. CRDs included in OCP 4.19+. Separate role model (infra vs app).
- **Cons:** Some advanced Istio features (fault injection) still have no Gateway API equivalent.

### Option 2: Istio Gateway + VirtualService
- **Pros:** Mature API with more features (fault injection, mirroring).
- **Cons:** **Technology Preview in ambient mode.** Cannot be mixed with Gateway API. Not supported for waypoint proxies.

### Option 3: Mix both APIs
- **Pros:** None relevant.
- **Cons:** **Explicitly discouraged by Red Hat.** Can cause configuration conflicts.

## Decision

Use Kubernetes Gateway API exclusively (`Gateway`, `HTTPRoute`) for all ingress, routing, and waypoint proxy configuration. Do not use VirtualService or Istio Gateway in any resource.

## Consequences

### Positive
- 100% supported, GA configuration in ambient mode.
- Portability: the same resources work in any Gateway API implementation.
- Consistency: a single API model for ingress and waypoint.

### Negative
- Three VirtualService-only features cannot be used in GA: **fault injection** (inject delays/errors), **traffic mirroring** (copy traffic to shadow), and **URL rewrite** (modify path). These are only available via VirtualService, which is **TP** in ambient mode.
- However, most traffic management features DO have GA equivalents: path/header routing (HTTPRoute), traffic shifting/canary (HTTPRoute weights), timeouts/retries/circuit breaking (DestinationRule GA), header manipulation and redirects (HTTPRoute filters).

### Neutral
- Waypoint proxies REQUIRE Gateway API regardless of this decision; there is no alternative.
- If fault injection or mirroring is needed for testing in the future, VirtualService can be used as TP accepting that it has no Red Hat SLA, or wait for Gateway API to incorporate these features.

## Official support matrix in Ambient Mode (SM3 3.3)

Source: [SM3 3.3 Feature Support Tables sec. 3.10](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/release_notes/ossm-release-notes-feature-support-tables)

| Feature | Status | API |
|---------|--------|-----|
| Waypoint: Gateway API (HTTPRoute, GRPCRoute) | **GA** | Gateway API |
| Waypoint: DestinationRule | **GA** | Istio API |
| Waypoint: VirtualService | **TP** | Istio API |
| Gateway API Experimental (TLSRoute, TCPRoute) | DP | Gateway API |
| Waypoint: WasmPlugin | DP | Istio API |
| AuthorizationPolicy, PeerAuthentication | **GA** | Istio API |

**GA features available without VirtualService:**
- Routing: path, header, method matching (HTTPRoute)
- Traffic shifting / canary (HTTPRoute backendRef weights)
- Timeouts, retries, connection pools, outlier detection (DestinationRule)
- Header manipulation, redirects (HTTPRoute filters)
- gRPC routing (GRPCRoute)

**Features only in VirtualService (TP, no SLA):**
- Fault injection (delay, abort)
- Traffic mirroring
- URL rewrite

## References

- [SM3 3.3 Feature Support Tables sec. 3.10](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/release_notes/ossm-release-notes-feature-support-tables): Official feature support matrix in ambient mode
- [SM3 3.3 Gateways sec. 2.5](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-getting-traffic-into-a-mesh): "Service Mesh classifies VirtualService resources as Technology Preview (TP) in ambient mode"
- [SM3 3.3 Gateways sec. 2.6](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-getting-traffic-into-a-mesh): "Service Mesh recommends the Kubernetes Gateway API for ingress configuration in ambient mode"
- [Blog: Introducing SM3 3.1](https://www.redhat.com/en/blog/introducing-openshift-service-mesh-31): "Kubernetes Gateway API is the next generation of Kubernetes Ingress... required for using Istio's ambient mode"
