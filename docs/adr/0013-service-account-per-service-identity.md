# ADR-0013: One ServiceAccount per logical service as identity unit

## Status

Accepted

## Context

In Istio ambient mode, workload identity is based exclusively on the Kubernetes ServiceAccount. Each pod receives an X.509 certificate with SPIFFE identity derived from its SA:

```
spiffe://cluster.local/ns/<namespace>/sa/<service-account>
```

This identity is used in:
- **mTLS**: ztunnel presents the sending pod's SA certificate to the destination.
- **AuthorizationPolicy**: `principals` and `serviceAccounts` reference SAs as the identity source.
- **ztunnel certificates**: one certificate per unique SA on the node (ADR-0012).

ServiceAccount granularity directly determines access control granularity. If two services share an SA, they share identity and cannot be distinguished in policies. If an entire namespace uses the `default` SA, the whole namespace has the same identity.

In a scenario with 300 applications per namespace, SA creation policy has direct impact on security, scalability, and operations.

## Options Considered

### Option 1: One ServiceAccount per logical service (chosen)
- **Pros:** Exact granularity for service-to-service AuthorizationPolicies. Versions of the same service (v1, v2, v3) share identity, simplifying canary deployments and traffic splitting. Fewer ztunnel certificates than one SA per version. Pattern recommended by Istio (bookinfo example).
- **Cons:** Requires discipline to create the SA alongside each Deployment. Does not allow distinguishing versions in policies (uncommon but possible).

### Option 2: One ServiceAccount per version/Deployment
- **Pros:** Maximum granularity. Allows distinct policies per version.
- **Cons:** With 300 services and multiple versions, SAs multiply unnecessarily. AuthorizationPolicies must be updated every time a new version is deployed. Complicates canary deployments: the new version does not have the same identity as the previous one. More ztunnel certificates per node.

### Option 3: Default ServiceAccount (or shared by group)
- **Pros:** Zero additional configuration.
- **Cons:** All pods in the namespace share identity. Impossible to write granular policies. Violates least privilege. Cannot distinguish caller from callee.

## Decision

Adopt the policy of **one ServiceAccount per logical service**, defined as:

### Rule 1: Each logical service has its own ServiceAccount

A "logical service" is the set of Deployments implementing the same functionality (including different versions). All versions share the same SA.

Example (bookinfo, already implemented in this PoC):
```yaml
# One SA for the "reviews" service
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bookinfo-reviews
---
# reviews-v1 uses the shared SA
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v1
spec:
  template:
    spec:
      serviceAccountName: bookinfo-reviews
---
# reviews-v2 uses the same SA
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v2
spec:
  template:
    spec:
      serviceAccountName: bookinfo-reviews
---
# reviews-v3 uses the same SA
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v3
spec:
  template:
    spec:
      serviceAccountName: bookinfo-reviews
```

Source: [Istio RBAC setup](https://istio.io/v0.5/docs/tasks/security/role-based-access-control): bookinfo creates `bookinfo-reviews` for reviews-v1/v2/v3

This pattern is validated in the current project, where the custom apps follow the same convention:

```yaml
# charts/apps: SA "app-a" for the app-a service
# charts/apps: SA "app-b" for the app-b service
# charts/apps: SA "app-c" for the app-c service
```

### Rule 2: Never use the default ServiceAccount

All pods participating in the mesh must specify `serviceAccountName` explicitly. The `default` SA makes the entire namespace share the same SPIFFE identity, nullifying the ability to write granular policies.

Source: [Istio Security Concepts](https://istio.io/latest/docs/concepts/security/): "The Istio identity model uses the first-class service identity to determine the identity of a request's origin"

### Rule 3: Name the SA the same as the service

Convention: the SA has the same name as the Kubernetes Service (or a consistent prefix as in bookinfo). This facilitates traceability between SPIFFE identity and the service:

```
Service: app-a      → SA: app-a      → spiffe://cluster.local/ns/mesh-apps/sa/app-a
Service: app-b      → SA: app-b      → spiffe://cluster.local/ns/mesh-apps/sa/app-b
Service: details    → SA: bookinfo-details → spiffe://cluster.local/ns/bookinfo/sa/bookinfo-details
```

### Rule 4: The SA is created in the same template as the Deployment

The SA must be created as part of the service chart/template, not managed separately. This ensures no Deployments exist without a dedicated SA.

Current example:
```yaml
# charts/apps/templates/app-a.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.appA.name }}
  namespace: {{ .Values.namespace }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.appA.name }}
spec:
  template:
    spec:
      serviceAccountName: {{ .Values.appA.name }}
```

### Rule 5: Separate SAs per version only when explicitly needed

The only case where versions of the same service need distinct SAs is when they have different authorization profiles. For example, if `reviews-v3` needs access to an external service that `reviews-v1` does not. This case must be documented explicitly as an exception.

### Interaction with AuthorizationPolicies

The dual enforcement model (ztunnel L4 + waypoint L7) and AuthorizationPolicy patterns are documented in ADR-0008. The SA-per-service decision complements that model: each SA becomes a `principal` referenced in policies.

If two services share an SA, policies cannot distinguish them. If the `default` SA is used, all granularity of the ADR-0008 model is lost.

### Interaction with ztunnel and certificates (ADR-0012)

The number of unique ServiceAccounts per node determines the number of certificates ztunnel must manage:

| Scenario | Pods/node | Unique SAs/node | ztunnel certificates |
|---|---|---|---|
| Default SA | 100 | 1 | 1 (no granularity) |
| SA per service | 100 | ~20-30 | ~20-30 |
| SA per version | 100 | ~50-80 | ~50-80 |

With 20-30 unique SAs per node, ztunnel manages 20-30 certificates and their rotations (~every 24h). This is negligible overhead compared to sidecar mode (100 certificates for 100 pods).

The Istio CA (istiod) validates that ztunnel only requests certificates for SAs that actually run on its node, limiting the blast radius of a compromised node.

Source: [Istio Architecture: ztunnel.md](https://github.com/istio/istio/blob/master/architecture/ambient/ztunnel.md)

## Consequences

### Positive
- Exact granularity for AuthorizationPolicies: each service has a unique identity.
- Canary deployments without friction: the new version inherits the identity (and policies) of the existing service.
- ztunnel certificates proportional to the number of services, not pods (efficiency per ADR-0012).
- Policies do not change when scaling replicas or deploying new versions.
- Pattern already validated in the current PoC (custom apps and bookinfo).

### Negative
- Requires discipline from development teams: each new service must create its SA.
- If templates do not include the SA, the Deployment silently uses `default`.
- Does not allow distinguishing versions in policies (rare but possible in blue/green with distinct access profiles).

### Neutral
- The `serviceAccounts` field in AuthorizationPolicy (`namespace/sa-name` format) is a simpler alternative to `principals` (full SPIFFE format). Both are valid.
- Istio Gateway ServiceAccounts (e.g. `app-gateway-aws-istio`) follow the same principle: unique identity for ingress policies.

## References

Related ADRs:
- ADR-0008: dual enforcement model (ztunnel L4 + waypoint L7) and AuthorizationPolicy patterns
- ADR-0012: ztunnel scalability and certificates per ServiceAccount

Primary sources (Red Hat docs):
- [SM3 3.3 Installing sec. 4.9-4.11](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): AuthorizationPolicy with targetRefs and principals in ambient mode
- [SM3 3.2 Installing sec. 4.5](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-istio-ambient-mode): "Waypoint proxy: runs per service account or namespace"

Secondary sources (upstream Istio):
- [Istio Security Concepts](https://istio.io/latest/docs/concepts/security/): SPIFFE identity model based on SA
- [Istio: Authorization Policy API](https://istio.io/latest/docs/reference/config/security/authorization-policy/): `principals` and `serviceAccounts` fields
- [Istio: Enforce authorization policies (Getting Started)](https://istio.io/latest/docs/ambient/getting-started/enforce-auth-policies/): complete bookinfo example
- [Istio Architecture: ztunnel.md](https://github.com/istio/istio/blob/master/architecture/ambient/ztunnel.md): certificates per SA, CA validation
