# ADR-0007: Waypoint proxy with L7 path routing

## Status

Accepted

## Context

In ambient mode, the waypoint proxy is an Envoy that performs L7 processing for workloads. It is deployed as a `Gateway` with `gatewayClassName: istio-waypoint` and an HBONE listener on port 15008.

To demonstrate L7 routing, internal traffic must be routed to different backends based on the HTTP request path. The pattern documented by Red Hat in the bookinfo example uses `HTTPRoute` with `parentRefs` pointing to a `Service` to split traffic between service versions.

## Options Considered

### Option 1: Virtual "backend" Service + HTTPRoute with path routing (chosen)
- **Pros:** Clearly demonstrates the waypoint L7 routing capability. The HTTPRoute splits traffic by path prefix (`/app-b` -> app-b, `/app-c` -> app-c). Pattern analogous to the bookinfo documentation (reviews -> reviews-v1/v2).
- **Cons:** Requires an additional "backend" Service as the routing entry point.

### Option 2: App A calls app-b and app-c directly by service name
- **Pros:** Simpler. Does not require a virtual Service.
- **Cons:** The waypoint does not perform L7 path routing; only policy enforcement. Does not demonstrate HTTPRoute path-based routing.

### Option 3: HTTPRoute with parentRef to the waypoint Gateway (not the Service)
- **Pros:** Applies to all waypoint traffic.
- **Cons:** Too broad. Does not demonstrate granular per-service routing.

## Decision

Create a `backend` Service whose endpoints include app-b and app-c pods (using a shared label `mesh-poc/role: backend`). Configure an HTTPRoute with `parentRefs` to the `backend` Service that routes by path prefix:

```yaml
parentRefs:
  - kind: Service
    group: ""
    name: backend
    port: 8080
rules:
  - matches:
    - path: {type: PathPrefix, value: /app-b}
    backendRefs:
    - {name: app-b, port: 8080}
  - matches:
    - path: {type: PathPrefix, value: /app-c}
    backendRefs:
    - {name: app-c, port: 8080}
```

App A is configured with an nginx reverse proxy to forward `/app-b` and `/app-c` to `http://backend:8080/...`.

## Example 2: Bookinfo -- Weight-based traffic splitting (official Red Hat example)

The official Red Hat example (SM3 3.3 Installing sec. 4.10) demonstrates another L7 routing pattern with waypoint: **weight-based traffic splitting** between service versions.

Bookinfo is deployed in ambient mode with a waypoint proxy and an HTTPRoute that splits traffic between `reviews-v1` (90%) and `reviews-v2` (10%):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
  namespace: bookinfo
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-v1
      port: 9080
      weight: 90
    - name: reviews-v2
      port: 9080
      weight: 10
```

### Verified cluster deployment

```bash
# Namespace with ambient mode
oc create namespace bookinfo
oc label namespace bookinfo istio.io/dataplane-mode=ambient istio-discovery=enabled

# Bookinfo application
oc apply -n bookinfo -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.30/samples/bookinfo/platform/kube/bookinfo.yaml
oc apply -n bookinfo -f https://raw.githubusercontent.com/openshift-service-mesh/istio/release-1.30/samples/bookinfo/platform/kube/bookinfo-versions.yaml

# Waypoint proxy
oc apply -f waypoint.yaml  # Gateway with gatewayClassName: istio-waypoint
oc label namespace bookinfo istio.io/use-waypoint=waypoint

# Traffic splitting HTTPRoute
oc apply -f traffic-route.yaml
```

### Test results (20 requests from ratings pod)

```
reviews-v1: 17/20 (85%)  -- expected ~90%
reviews-v2:  3/20 (15%)  -- expected ~10%
reviews-v3:  0/20 (0%)   -- correctly excluded
```

The waypoint correctly applies weight-based traffic splitting, confirming that L7 routing works for both **path-based routing** (our backend/app-b/app-c example) and **weighted traffic splitting** (bookinfo reviews-v1/v2 example).

## L7 pattern comparison

| Pattern | Example | parentRef | Routing criterion |
|--------|---------|-----------|---------------------|
| Path-based routing | PoC (backend -> app-b/app-c) | Service `backend` | `matches.path.value: /app-b` |
| Weight-based splitting | Bookinfo (reviews -> v1/v2) | Service `reviews` | `backendRefs.weight: 90/10` |

Both patterns use the same mechanism: `HTTPRoute` with `parentRefs` pointing to a Service, enforced by the waypoint proxy. The difference is the selection criterion (path prefix vs weight).

## Consequences

### Positive
- Demonstrates the full L7 routing capability of the waypoint proxy.
- Two patterns validated empirically: path-based and weight-based.
- Traffic path: App A -> ztunnel -> waypoint (HTTPRoute) -> app-b/app-c.
- Bookinfo deployed and validated as an additional reference example.

### Negative
- Requires an additional virtual "backend" Service that is not strictly necessary for communication (applies only to the PoC example, not bookinfo).

### Neutral
- The "backend" Service has real endpoints (app-b and app-c pods), ensuring ztunnel treats it as a valid target.
- Bookinfo uses the original Istio architecture (productpage -> reviews -> ratings) without modifications.

## References

- [SM3 3.3 Installing sec. 4.4](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "Deploying the Bookinfo application in Istio ambient mode"
- [SM3 3.3 Installing sec. 4.7](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "Deploying a waypoint proxy"
- [SM3 3.3 Installing sec. 4.10](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "Routing traffic using waypoint proxies" -- reviews-v1/v2 traffic splitting example
- [SM3 3.3 Installing sec. 4.5](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "About waypoint proxies in Istio ambient mode"
