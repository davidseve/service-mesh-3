# ADR-0008: Zero Trust -- dual ztunnel + waypoint model

## Status

Accepted

## Context

In ambient mode, security is enforced at **two separate enforcement points**:

1. **ztunnel (L4)**: Per-node proxy. Applies mTLS, workload identity, and L4 policies based on `selector` (workload selector). Can only evaluate L4 attributes (source principal, port).
2. **waypoint (L7)**: Per-namespace proxy. Applies L7 policies based on `targetRefs` (pointing to Service or Gateway). Can evaluate HTTP attributes (method, path, headers).

A common mistake is creating an AuthorizationPolicy with `selector` that includes L7 rules (methods, paths). In ambient mode, ztunnel CANNOT evaluate L7 attributes; if forced, the policy becomes a total DENY for safety (fail-safe).

Additionally, ztunnel **always** enforces mTLS on HBONE traffic. A PeerAuthentication with `mode: STRICT` has no real effect because no non-mesh traffic can reach a pod enrolled in ambient. It is discarded as redundant.

**Two use cases** with different security requirements are identified:

| | UC1: Known graph | UC2: Unknown graph |
|---|---|---|
| **Services** | Few, known relationships | Many, unknown relationships |
| **Cross-namespace** | Possible | Not allowed |
| **Policies** | Explicit ALLOW per service-to-service pair | Single intra-namespace ALLOW |
| **Scalability** | O(N²) policies | O(1) policies |
| **Anti-bypass** | DENY per backend | Not needed (ALLOW on Gateway covers all) |

The security chart uses `securityMode` in values.yaml to select the mode.

## Options Considered

### Option 1: ALLOW with targetRefs + DENY anti-bypass (UC1)
- **Pros:** Correct model for ambient mode. ALLOW creates implicit denial (everything not allowed is blocked). DENY with `notPrincipals` in ztunnel prevents waypoint bypass.
- **Cons:** Requires knowing the call graph. Does not scale with many services (O(N²) policies).

### Option 2: Intra-namespace ALLOW on waypoint Gateway (UC2)
- **Pros:** A single policy covers all services in the namespace. Scales to N services with O(1) policies. Implicit cross-namespace blocking.
- **Cons:** Does not distinguish caller within the namespace. Coarse granularity.

### Option 3: Global deny-all + explicit ALLOWs
- **Pros:** Intuitive for those familiar with sidecar mode.
- **Cons:** A deny-all with empty spec in ambient mode blocks ALL traffic including ingress Gateway pods. Requires complex exceptions.

### Option 4: L4 policies only in ztunnel
- **Pros:** Simple.
- **Cons:** HTTP methods and paths cannot be validated. No L7 enforcement.

## Decision

Support both use cases, selectable via `securityMode` in values.yaml:

### UC1: `securityMode: explicit` (known graph)

**Layer 1 -- ALLOW with targetRefs** (waypoint, L7):
ALLOW policies per Service that validate ServiceAccount + HTTP methods. When an ALLOW exists for a Service, all non-matching traffic is implicitly denied.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-app-a-to-backends
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: app-b
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/mesh-apps/sa/app-a"]
```

**Layer 2 -- DENY anti-bypass** (ztunnel, L4):
DENY policy with `selector` that blocks traffic not coming from the waypoint, preventing an attacker from bypassing the waypoint to evade L7 policies.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-waypoint-bypass
spec:
  selector:
    matchLabels:
      app: app-b
  action: DENY
  rules:
  - from:
    - source:
        notPrincipals: ["cluster.local/ns/mesh-apps/sa/waypoint"]
```

### UC2: `securityMode: namespace-isolation` (unknown graph)

**Single ALLOW policy on the waypoint Gateway:**
Allows all traffic originating in the same namespace. Cross-namespace traffic is implicitly denied. DENY anti-bypass policies are not needed because the policy targets the Gateway (waypoint), which is already the mandatory enforcement point.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-same-namespace
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["mesh-apps"]
```

### PeerAuthentication STRICT (discarded in both UCs)

In ambient mode, ztunnel always enforces mTLS via HBONE; it cannot be disabled. Removed as redundant.

## Consequences

### Positive
- Two modes cover the spectrum: granular security (UC1) and simple isolation (UC2).
- UC2 scales to hundreds of services without policy explosion.
- In both modes, ztunnel always enforces mTLS.
- UC1 offers defense-in-depth: L4 (ztunnel) + L7 (waypoint).

### Negative
- UC1 requires keeping policies synchronized with ServiceAccounts.
- UC2 does not distinguish caller within the namespace (coarse granularity).
- Switching from UC2 to UC1 requires mapping the call graph (observable via Kiali).

### Neutral
- PeerAuthentication STRICT is discarded as redundant in both UCs.
- UC2 can evolve toward UC1 progressively: observe with Kiali, discover the graph, and create explicit policies.

## References

- [SM3 3.3 Installing sec. 4.11](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "Adding authorization policy" with targetRefs in ambient mode
- [Istio: Migrate policies](https://istio.io/latest/docs/ambient/migrate/migrate-policies/): "When a waypoint is used, ensure that workloads cannot be reached by bypassing it"
- [SM3 3.3 Installing sec. 4.9](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "ztunnel and HBONE ignore policies that set the mode to DISABLE because they always enforce mTLS"
