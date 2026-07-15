# ADR-0011: Simple nginx apps + virtual backend

## Status

Accepted

## Context

The PoC needs three microservices (App A frontend, App B backend, App C backend) that demonstrate mesh capabilities. The apps must be simple enough not to distract from the main goal (learning service mesh), but functional enough to demonstrate routing, security, and observability.

Additionally, a `backend` Service is needed as a virtual entry point for waypoint L7 routing (ADR-0007).

## Options Considered

### Option 1: nginx with ConfigMaps (chosen)
- **Pros:** Official, lightweight image (~20MB). Configuration via ConfigMap (no custom image builds). Easy to customize (JSON responses, reverse proxy). Universally available in registries.
- **Cons:** Not a "real" microservice with business logic.

### Option 2: httpbin
- **Pros:** More test endpoints (headers, status, delay).
- **Cons:** Heavier image. Less clear responses for identifying which service responded.

### Option 3: Custom applications (Go/Python)
- **Pros:** More realistic. Business logic can be added.
- **Cons:** Requires building and publishing images. Unnecessary complexity for a service mesh PoC.

## Decision

Use nginx with custom ConfigMaps:

- **App A**: nginx with reverse proxy forwarding `/app-b` and `/app-c` to `http://backend:8080/...`
- **App B**: nginx returning `{"app":"app-b","version":"v1"}`
- **App C**: nginx returning `{"app":"app-c","version":"v1"}`
- **backend** Service: Selector `mesh-poc/role: backend` shared by app-b and app-c pods. Serves as the entry point for the waypoint HTTPRoute.

Each app has its own ServiceAccount to enable identity-based AuthorizationPolicies.

## Consequences

### Positive
- Fast deployment without building custom images.
- Clear JSON responses that identify which service responded.
- The `backend` Service enables demonstration of waypoint path-based routing.

### Negative
- Apps have no real business logic.
- App A reverse proxy adds a level of indirection.

### Neutral
- The traffic generator (fortio/curl loop) complements the apps to generate data in Kiali.

## References

- Project decision (no Red Hat documentation reference required).
- ADR-0007: Waypoint L7 path routing (explains why the `backend` Service is needed)
