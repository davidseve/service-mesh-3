# Service Mesh 3 (Sidecar) → Service Mesh 3 (Ambient Mode) Migration

## New Deployment on a New Cluster — Manifest Translation Guide

> **Context:** Starting from a production environment with **OpenShift Service Mesh 3.x** (Sail Operator, sidecar mode), a **new cluster** is deployed with **OpenShift Service Mesh 3.3** (Sail Operator, ambient mode). There is no in-place upgrade or temporary coexistence — the new cluster starts directly with ambient mode. For the rationale behind choosing ambient over sidecar, see [ADR-0004: Ambient mode vs Sidecar mode](adr/0004-ambient-mode-vs-sidecar.md).

> **Implementation status in the repository:**
> This document serves as a complete reference guide for migration. Some sections describe the target architecture that is already implemented in the repository charts, and others describe recommended practices that are not yet materialized. In particular:
> - Control plane, IstioCNI, ZTunnel, Gateway API, and AuthorizationPolicies (`securityMode: explicit`) are **implemented**.
> - Tracing (Telemetry + extensionProviders), metrics (PodMonitor/ServiceMonitor), and declarative waypoint labels are **implemented**.
> - `securityMode: namespace-isolation` is **implemented** as a selectable alternative.
> - Operator version pinning (`startingCSV`) is prepared but **commented out** by default.
> - This guide documents the GitOps pattern with ArgoCD sync-waves that is **not deployed** in the repo (Makefile + Helm is used directly instead).

```
┌──────────────────────────┐              ┌──────────────────────────┐
│  SOURCE CLUSTER          │              │  DESTINATION CLUSTER     │
│                          │              │                          │
│  OCP 4.19+               │   Translate │  OCP 4.19+               │
│  SM 3.x (Sail Operator) │ ──────────► │  SM 3.3 (Sail Operator) │
│  Sidecar mode            │  manifests  │  Ambient mode            │
│  Istio CR (no profile)   │              │  Istio CR (profile:      │
│  VirtualService          │              │    ambient) + ZTunnel CR │
│  istio-injection=enabled │              │  HTTPRoute               │
│  Sidecar proxy per pod   │              │  dataplane-mode=ambient  │
└──────────────────────────┘              └──────────────────────────┘
```

> **Official sources used:**
> - [Red Hat OpenShift Service Mesh 3.3 - Installing Ambient Mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)
> - [Red Hat OpenShift Service Mesh 3.3 - Gateways](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-getting-traffic-into-a-mesh)
> - [Red Hat OpenShift Service Mesh 3.3 - Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html-single/observability/index)
> - [Istio Upstream - Migrate from Sidecar to Ambient](https://istio.io/latest/docs/ambient/migrate/)
> - [Istio Upstream - Before you begin](https://istio.io/latest/docs/ambient/migrate/before-you-begin/)
> - [Istio Upstream - Migrate policies](https://istio.io/latest/docs/ambient/migrate/migrate-policies/)
> - [Istio Upstream - Enable ambient mode](https://istio.io/latest/docs/ambient/migrate/enable-ambient-mode/)

---

## GitOps Approach

This document assumes a **declarative environment managed with GitOps** (ArgoCD / OpenShift GitOps). All changes are made as YAML manifest modifications in the Git repository and applied to the new cluster through automatic synchronization.

**Principles:**
- The Git repository is the **single source of truth** for the desired state
- Migration is materialized as a **new branch or directory** in the repo with manifests translated from sidecar to ambient
- The **Sail Operator** is already used in the source environment — the main changes are the Istio CR `profile`, the addition of the ZTunnel CR, and the translation of policy/routing resources
- ArgoCD `sync-waves` ensure the correct order of resource application
- There are no sidecars in the destination cluster — pods are deployed directly without `istio-proxy`

---

## 1. Infrastructure Prerequisites

### 1.1 Minimum Required Versions

| Component | Minimum Version | Source |
|---|---|---|
| OpenShift Container Platform | 4.19+ | docs.redhat.com SM3 3.3 Installing |
| OpenShift Service Mesh Operator | 3.1.0+ (recommended 3.2.0+) | docs.redhat.com SM3 3.3 Installing |
| Gateway API CRDs | Included in OCP 4.19+ | docs.redhat.com SM3 3.3 Installing |

### 1.2 OVN-Kubernetes Network Configuration (REQUIRED)

Ambient mode requires configuring OVN-Kubernetes in **local gateway** mode (`routingViaHost: true`).

**Required action:** Include the Network Operator manifest with the following configuration in the repository:

```yaml
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    ovnKubernetesConfig:
      gatewayConfig:
        routingViaHost: true
```

**Reason:** In local mode, traffic is routed through the host and the host processes it using the routing table, ensuring that liveness/readiness probes work correctly with ztunnel.

For the full analysis of why this is a hard prerequisite, see [ADR-0002: OVN routingViaHost required for ambient mode](adr/0002-ovn-routingviahost-required.md).

> Source: docs.redhat.com SM3 3.3 Installing - "You have configured the OVN-Kubernetes Container Network Interface (CNI) to use local gateway mode by setting the routingViaHost field as true in the gatewayConfig specification for the Cluster Network Operator."

### 1.3 RHEL 10 / RHCOS 10 (if applicable)

If the cluster uses RHEL 10 or RHCOS 10 nodes, it is necessary to add `nativeNftables: true` in the Istio CR configuration.

```yaml
spec:
  values:
    global:
      nativeNftables: true
```

> Source: docs.redhat.com SM3 3.3 Installing

---

## 2. Migration Blockers (Hard Blockers)

These items **prevent** migration until they are resolved:

| Blocker | Detail | Required Action |
|---|---|---|
| `PeerAuthentication` with `mode: DISABLE` | Ambient mode always enforces mTLS between mesh workloads. It cannot be disabled. | Remove or change to STRICT/PERMISSIVE before migrating |
| `EnvoyFilter` in use | Not supported on waypoint proxies. Silently ignored post-migration. | Evaluate whether a `WasmPlugin` can replace it. If there is no alternative, it is a blocker. |
| VM workloads in the mesh | VM-based workloads cannot join the ambient mesh | Exclude VMs from the ambient mesh or find an alternative |
| SPIRE as certificate provider | Ambient mode does not support SPIRE integration | Migrate to Istio's default certificate provider |
| Multi-cluster primary-remote | Only multiple-primary configurations are supported | Restructure multi-cluster if applicable |

> Source: istio.io - Migrate from Sidecar to Ambient - "What is not supported"

---

## 3. Policy Resource Changes

### 3.1 VirtualService → HTTPRoute (CRITICAL)

| Aspect | Sidecar Mode | Ambient Mode |
|---|---|---|
| Recommended API | `VirtualService` (networking.istio.io/v1) | `HTTPRoute` (gateway.networking.k8s.io/v1) |
| VirtualService support | GA (stable) | **Alpha / Technology Preview** — Not recommended |
| Mixing APIs | N/A | **Forbidden** to mix VirtualService and HTTPRoute for the same workload |

**Required action:**
1. Inventory all `VirtualService` manifests in the Git repository
2. Create the equivalent `HTTPRoute` for each one
3. The `parentRef` in HTTPRoute must point to the `Service` (not the ingress Gateway) for internal mesh routing
4. Remove VirtualService manifests from the repo once HTTPRoute is validated

For the full rationale behind Gateway API over Istio APIs, including the official GA/TP support matrix, see [ADR-0005: Gateway API vs Istio Gateway/VirtualService](adr/0005-gateway-api-vs-istio-gateway.md).

**Migration example:**

```yaml
# BEFORE (Sidecar): VirtualService with subsets
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - match:
    - headers:
        end-user:
          exact: jason
    route:
    - destination:
        host: reviews
        subset: v2
  - route:
    - destination:
        host: reviews
        subset: v1
```

```yaml
# AFTER (Ambient): Services per version + HTTPRoute
apiVersion: v1
kind: Service
metadata:
  name: reviews-v1
spec:
  selector:
    app: reviews
    version: v1
  ports:
  - port: 9080
    name: http
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v2
spec:
  selector:
    app: reviews
    version: v2
  ports:
  - port: 9080
    name: http
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: reviews
    port: 9080
  rules:
  - matches:
    - headers:
      - name: end-user
        value: jason
    backendRefs:
    - name: reviews-v2
      port: 9080
  - backendRefs:
    - name: reviews-v1
      port: 9080
```

**Alternative: A single Service with all pods and HTTPRoute with `backendRefs` per version.**

If traffic splitting by separate versions is not needed, a single Service that selects all versions can be kept, using HTTPRoute only for header or path matching. `backendRefs` per version are only needed when traffic must be directed to specific pod subsets (as in the example above). If routing is uniform (round-robin across all versions), the following is sufficient:

```yaml
# Alternative: Single Service + simple HTTPRoute (no version split)
apiVersion: v1
kind: Service
metadata:
  name: reviews
spec:
  selector:
    app: reviews    # selects ALL versions
  ports:
  - port: 9080
    name: http
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews
      port: 9080
```

In this case, Kubernetes distributes traffic across all pods matching `app: reviews` without version distinction. Per-version Services are **only needed when explicit traffic splitting is required** (percentages, header-based routing to specific versions, canary, etc.).

> Source: istio.io - Migrate policies; docs.redhat.com SM3 3.3 Gateways - "Service Mesh classifies VirtualService resources as Technology Preview (TP) in ambient mode. Therefore, you should not mix them with Gateway API configuration."

### 3.2 DestinationRule

| Aspect | Action in Ambient |
|---|---|
| Traffic policies (connection pool, outlier detection, TLS) | **No changes** — Waypoints apply traffic policies |
| Routing subsets used with HTTPRoute | **Create version-specific Services** as `backendRefs` for HTTPRoute |

> Source: istio.io - Migrate from Sidecar to Ambient

### 3.3 AuthorizationPolicy

#### L4 policies (principal, namespace, IP only)

**No changes required.** They are applied directly by ztunnel.

```yaml
# Works the same in ambient — no changes
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend
spec:
  selector:
    matchLabels:
      app: reviews
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/bookinfo/sa/productpage"]
```

#### L7 policies (methods, paths, headers, CUSTOM, AUDIT) — CHANGES REQUIRED

**Required action:** Replace `selector` with `targetRefs` pointing to the `Service` or the waypoint `Gateway`.

AuthorizationPolicies use `principals` based on ServiceAccounts as identity. For naming conventions and SA granularity, see [ADR-0013: One ServiceAccount per logical service](adr/0013-service-account-per-service-identity.md).

```yaml
# BEFORE (Sidecar): selector-based
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-get-reviews
spec:
  selector:
    matchLabels:
      app: reviews
  action: ALLOW
  rules:
  - to:
    - operation:
        methods: ["GET"]
```

```yaml
# AFTER (Ambient): targetRefs pointing to the Service
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-get-reviews
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: reviews
  action: ALLOW
  rules:
  - to:
    - operation:
        methods: ["GET"]
```

> Source: istio.io - Migrate policies; docs.redhat.com SM3 3.3 Installing - "To attach a policy to a waypoint, include a targetRef that references either the waypoint itself or a Service configured to use that waypoint."

### 3.4 RequestAuthentication (JWT)

**Required action:** Requires a waypoint proxy and must use `targetRefs` instead of `selector`.

> Source: istio.io - Migrate policies

### 3.5 WasmPlugin

**Required action:** Requires a waypoint proxy and must use `targetRefs` to point to the waypoint.

> Source: istio.io - Migrate policies

### 3.6 PeerAuthentication

| Current mode | Required action |
|---|---|
| `DISABLE` | **BLOCKER** — Remove or change before migrating |
| `STRICT` | Redundant post-migration (ztunnel always enforces mTLS). Can be removed afterward. |
| `PERMISSIVE` | Redundant post-migration. Can be removed afterward. |

> Source: istio.io - Before you begin - "ambient mode enforces mTLS via ztunnel regardless of these policies. You can safely remove them after migration is complete."

### 3.7 Sidecar Resource (CRD `Sidecar`)

The Istio `Sidecar` resource (to limit service visibility per sidecar) does not apply in ambient mode. If used to control discovery scope, it must be handled via `discoverySelectors` in the Istio CR.

---

## 4. Ingress / Gateway Changes

### 4.1 Istio Gateway + VirtualService (sidecar mode)

| Current resource | Action in Ambient |
|---|---|
| `Gateway` (networking.istio.io/v1) | Replace with `Gateway` (gateway.networking.k8s.io/v1) |
| `VirtualService` for ingress | Migrate to `HTTPRoute` with `parentRef` to the Kubernetes `Gateway` |

> **Note:** Although `networking.istio.io/v1` `Gateway` objects technically still work in ambient mode, this project uses exclusively Kubernetes Gateway API (see [ADR-0005: Gateway API vs Istio Gateway/VirtualService](adr/0005-gateway-api-vs-istio-gateway.md)). The migration action is to replace `networking.istio.io/v1 Gateway` with `gateway.networking.k8s.io/v1 Gateway`.

**Red Hat recommendation:** Use Kubernetes Gateway API for ingress configuration in ambient mode.

> Source: docs.redhat.com SM3 3.3 Gateways - "Service Mesh recommends the Kubernetes Gateway API for ingress configuration in ambient mode (istio.io/dataplane-mode=ambient), because Istio Gateway and VirtualService resources lack full compatibility."

### 4.2 Ingress routing through a waypoint

If ingress traffic needs to pass through a waypoint for L7 processing, declare the label in the Service manifest:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  labels:
    istio.io/ingress-use-waypoint: "true"
spec:
  # ...
```

> Source: docs.redhat.com SM3 3.3 Gateways

---

## 5. Data Plane Changes

### 5.1 New architecture model

| Component | Function |
|---|---|
| **ztunnel** (DaemonSet per node) | Transparent mTLS, L4 authorization, L4 telemetry, traffic redirection |
| **Waypoint proxy** (Deployment per namespace/service) | L7 routing, L7 authorization, L7 telemetry, tracing, rate limiting, retries |
| **Istio CNI** | Redirects traffic to ztunnel on each node without modifying pods |

### 5.2 Namespace Labels (declarative)

| Sidecar Mode | Ambient Mode |
|---|---|
| `istio-injection: enabled` | `istio.io/dataplane-mode: ambient` |
| `istio.io/rev: <revision>` | `istio.io/dataplane-mode: ambient` |

In GitOps, these labels are declared in the Namespace manifest:

```yaml
# BEFORE (Sidecar)
apiVersion: v1
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio-injection: enabled
```

```yaml
# AFTER (Ambient)
apiVersion: v1
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio.io/dataplane-mode: ambient
    istio.io/use-waypoint: waypoint    # if using a waypoint in this ns
```

### 5.3 Waypoint Proxies (Deployment)

Deployed using Gateway API with `gatewayClassName: istio-waypoint`. For L7 routing patterns through the waypoint (path-based, weight-based), see [ADR-0007: Waypoint proxy with L7 path routing](adr/0007-waypoint-l7-path-routing.md). For scaling (HPA, PDB, TopologySpread, per-service waypoints), see [ADR-0012: ztunnel and waypoint scalability in ambient mode](adr/0012-ztunnel-waypoint-scalability.md).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: bookinfo
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
```

Activation per namespace (in the Namespace manifest):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio.io/dataplane-mode: ambient
    istio.io/use-waypoint: waypoint
```

> **Note:** This repository uses **per-Service** activation (not per namespace) for greater granularity. The `istio.io/use-waypoint` label is declared directly in the manifests of each Service that requires L7 processing.

Activation per service (in the Service manifest — **pattern used in this repo**):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: reviews
  labels:
    istio.io/use-waypoint: waypoint
spec:
  # ...
```

> Source: docs.redhat.com SM3 3.3 Installing

### 5.4 Pods: No Sidecar Containers

As a new cluster, pods are deployed directly without a sidecar:

- Pods **will not have** an `istio-proxy` container injected — they deploy as `1/1` from the start
- No `restartedAt` annotation is needed — there are no sidecars to remove
- **Remove from the repo** any sidecar resource configuration (`sidecar.istio.io/proxyMemory`, `sidecar.istio.io/proxyCPU`, etc.)
- Sidecar `resource requests/limits` disappear — **recalculate** ResourceQuotas and LimitRanges in namespace manifests
- Remove any `istio-injection: enabled` or `istio.io/rev:` labels from Namespaces in the repo

---

## 6. Waypoint Bypass Prevention (Security)

When a waypoint is in use, workloads must not be reachable without passing through it.

**Required action:** Create a DENY policy in ztunnel (L4) that only allows traffic from the waypoint:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-waypoint-bypass
spec:
  selector:
    matchLabels:
      app: reviews
  action: DENY
  rules:
  - from:
    - source:
        notPrincipals:
        - "cluster.local/ns/<namespace>/sa/waypoint"
```

For the complete dual security model (ALLOW L7 on waypoint + DENY anti-bypass on ztunnel) and alternatives by use case, see [ADR-0008: Zero Trust -- dual ztunnel + waypoint model](adr/0008-zero-trust-dual-enforcement.md).

> Source: istio.io - Migrate policies - "Sidecar mode workloads bypass the waypoint and connect directly to ztunnel at the destination"

---

## 7. Deployment on a New Cluster — No Coexistence

### 7.1 Advantage of a new cluster

As a clean deployment, there is **no sidecar ↔ ambient coexistence**. This eliminates the following complexities:
- No need to enable HBONE on existing sidecars
- No waypoint bypass by sidecars
- No transition period with L7 enforcement gap
- No need to manage dual injection labels

The destination cluster starts directly with all namespaces in `istio.io/dataplane-mode: ambient` and without any sidecar injection labels.

### 7.2 What must still be guaranteed: deployment order

Although there is no coexistence, the order of resource application remains important. Waypoints must exist before L7 policies and HTTPRoutes are applied.

**Recommended ArgoCD sync waves:**

```yaml
# Control plane: Istio + IstioCNI + ZTunnel (wave 0)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
# Namespaces with ambient labels (wave 1)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
# Waypoint Gateway per namespace (wave 2)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"
---
# HTTPRoute, AuthorizationPolicy with targetRefs, deny-bypass (wave 3)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"
---
# Application Deployments (wave 4)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

> Source: istio.io - Enable ambient mode - "Failing to follow this sequence can result in traffic being processed by neither sidecar nor ztunnel, causing disruption in your workloads."

---

## 8. Observability Changes

### 8.1 Metrics

| Aspect | Sidecar Mode | Ambient Mode |
|---|---|---|
| Reporter label | `reporter="source"` and `reporter="destination"` | `reporter="source"` (ztunnel) and `reporter="waypoint"` (waypoint) |
| L4 metrics | TCP metrics from the sidecar | `istio_tcp_sent_bytes_total`, `istio_tcp_received_bytes_total`, `istio_tcp_connections_opened_total`, `istio_tcp_connections_closed_total` (ztunnel) |
| L7 metrics (HTTP) | Always available | Only with waypoint proxy deployed |
| Metrics merging | Supported (single Prometheus endpoint) | **Not supported** — separate scrape for ztunnel, waypoints, and application |

**Required actions:**
- Update dashboards and alerts that use the `reporter` label
- Update `PodMonitor` / `ServiceMonitor` for separate scraping
- Verify that Kiali has access to the `ztunnel` namespace

For the complete observability stack architecture (Kiali, Tempo, OTEL, Loki, Prometheus), see [ADR-0009: Red Hat observability stack](adr/0009-observability-stack-redhat.md).

> Source: istio.io - Enable ambient mode (Post-migration observability changes); docs.redhat.com SM3 3.3 Observability

### 8.2 Distributed Tracing

| Aspect | Sidecar Mode | Ambient Mode |
|---|---|---|
| Spans per hop | 2 (source sidecar + destination sidecar) | 1 per waypoint |
| L4-only (no waypoint) | N/A | No L7 traces are generated |
| Trace generation | Automatic with sidecar | Requires waypoint proxy deployed |

**Required actions:**
- Adjust SLOs based on traces
- Configure Telemetry API for tracing with waypoints
- Verify that the Istio CR has `enableTracing: true` and `extensionProviders` configured

> Source: docs.redhat.com SM3 3.3 Observability - Distributed tracing

### 8.3 Kiali in Ambient Mode

Kiali requires specific configuration for ambient:
- Access to the `ztunnel` namespace to detect ambient mode
- New visualizations: ambient badges, waypoint nodes in traffic graph
- Aggregated logs from ztunnel and waypoint proxies
- Automatic trace correlation with waypoint proxies

> Source: docs.redhat.com SM3 3.3 Observability - Kiali

### 8.4 Diagnostic Tools

| Sidecar Mode | Ambient Mode |
|---|---|
| `istioctl proxy-status` | **Does not show** ztunnel workloads |
| `istioctl proxy-config` | `istioctl ztunnel-config workloads` |
| Sidecar logs | ztunnel logs + waypoint logs |

> Source: istio.io - Enable ambient mode

---

## 9. Control Plane Changes (SM3 Sidecar → SM3 Ambient)

### 9.1 Istio CR — Differences

```yaml
# BEFORE (SM3 Sidecar mode) — no profile or default profile
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  namespace: istio-system
  # no explicit profile = sidecar mode
```

```yaml
# AFTER (SM3 Ambient mode)
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  namespace: istio-system
  profile: ambient                          # MAIN CHANGE
  values:
    pilot:
      trustedZtunnelNamespace: ztunnel      # NEW: reference to ztunnel ns
```

### 9.2 IstioCNI CR — Add ambient profile

```yaml
# BEFORE (SM3 Sidecar mode)
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  namespace: istio-cni
```

```yaml
# AFTER (SM3 Ambient mode)
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  namespace: istio-cni
  profile: ambient                          # NEW
```

### 9.3 ZTunnel CR (NEW — does not exist in sidecar mode)

This resource did not exist in the sidecar deployment. It must be added to the repo:

```yaml
apiVersion: sailoperator.io/v1alpha1
kind: ZTunnel
metadata:
  name: default
  namespace: ztunnel
spec:
  namespace: ztunnel
  profile: ambient
```

> **Note:** The ZTunnel version is managed by the Sail Operator based on the Istio CR version. `version` is not set explicitly unless a specific revision needs to be pinned for upgrade control.

### 9.4 ztunnel Namespace (NEW — does not exist in sidecar mode)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ztunnel
```

### 9.5 Component summary

| Component | In SM3 Sidecar | In SM3 Ambient | Change |
|---|---|---|---|
| Istio CR | Yes (no profile) | Yes (`profile: ambient` + `trustedZtunnelNamespace`) | Modify |
| IstioCNI CR | Yes (no profile) | Yes (`profile: ambient`) | Modify |
| ZTunnel CR | **Does not exist** | Yes | Add |
| `ztunnel` Namespace | **Does not exist** | Yes | Add |
| Sidecar injection | `istio-injection: enabled` on namespaces | **Remove** | Remove |
| Waypoint proxies | **Do not exist** | Gateway `istio-waypoint` per ns/service | Add |

> Source: docs.redhat.com SM3 3.3 Installing

---

## 10. Pre-Migration Audit Checklist

### 10.1 Resource Inventory in the Git Repository

In a GitOps environment, all configuration exists as manifests in the repository. The audit is performed on repo files, not against the cluster.

**Search the repository for the following resources that require evaluation:**

| What to search | Grep in the repo | Action |
|---|---|---|
| VirtualService | `kind: VirtualService` | Migrate to HTTPRoute |
| DestinationRule with subsets | `subsets:` within DestinationRule | Create Services per version |
| AuthorizationPolicy with L7 rules | `methods:`, `paths:`, `headers:`, `action: CUSTOM`, `action: AUDIT` | Migrate selector → targetRefs |
| PeerAuthentication with DISABLE | `mode: DISABLE` within PeerAuthentication | Remove from repo (blocker) |
| EnvoyFilter | `kind: EnvoyFilter` | Remove or replace with WasmPlugin (blocker) |
| RequestAuthentication | `kind: RequestAuthentication` | Migrate to targetRefs |
| WasmPlugin | `kind: WasmPlugin` | Migrate to targetRefs |
| Sidecar injection labels | `istio-injection: enabled` or `istio.io/rev:` | Replace with `istio.io/dataplane-mode: ambient` |

### 10.2 Configuration Backup

In GitOps, the backup is Git history itself. Before starting migration:

1. Create a **tag** or **branch** that marks the pre-migration state:

```bash
git tag pre-ambient-migration
git push origin pre-ambient-migration
```

2. If a snapshot of the actual cluster state is needed (to detect drift):

```bash
oc get virtualservice,destinationrule,authorizationpolicy,requestauthentication,peerauthentication,gateway,wasmplugin -A -o yaml > cluster-state-snapshot.yaml
```

This snapshot is used only to compare against the repo and detect resources not managed by GitOps.

> Source: istio.io - Before you begin

---

## 11. Resource Compatibility Summary

| Sidecar Resource | Action in Ambient Mode | Requires Waypoint |
|---|---|---|
| `VirtualService` | Migrate to `HTTPRoute` | Yes |
| `DestinationRule` (traffic policies) | No changes | Yes (waypoint applies them) |
| `DestinationRule` (subsets) | Create Services per version | Yes |
| `AuthorizationPolicy` (L4) | No changes | No (ztunnel) |
| `AuthorizationPolicy` (L7) | Change `selector` → `targetRefs` | Yes |
| `RequestAuthentication` | Change to `targetRefs` | Yes |
| `PeerAuthentication` (STRICT) | Redundant, remove post-migration | No |
| `PeerAuthentication` (DISABLE) | **BLOCKER** — remove | N/A |
| `EnvoyFilter` | **Not supported** | N/A |
| `WasmPlugin` | Change to `targetRefs` | Yes |
| `Gateway` (networking.istio.io) | No changes | No |
| `Sidecar` (CRD) | Not applicable — use `discoverySelectors` | No |
| Istio `Gateway` + `VirtualService` (ingress) | Migrate to K8s Gateway API | Depends |

---

## 12. Additional Considerations

### 12.1 Capacity Planning

- Sidecar CPU/memory overhead per pod is eliminated
- A ztunnel DaemonSet per node is added (shared consumption)
- Waypoint proxies scale like normal Deployments (HPA)
- A workload with many replicas shares ONE waypoint vs. having a sidecar each

For detailed scalability analysis with benchmarks, HPA, PDB, TopologySpread, and ztunnel/waypoint sizing at enterprise scale (8000 apps), see [ADR-0012: ztunnel and waypoint scalability in ambient mode](adr/0012-ztunnel-waypoint-scalability.md).

### 12.2 Latency

| Mode | p90/p99 Latency |
|---|---|
| Sidecar | 0.63ms - 0.88ms |
| Ambient (ztunnel only) | 0.16ms - 0.20ms |
| Ambient (with waypoint) | 0.40ms - 0.50ms |

> Source: istio.io - Sidecar or ambient?

### 12.3 Features Not Available in Ambient (as of documentation date)

- VM support
- `EnvoyFilter` API on waypoints
- Multi-cluster primary-remote
- SPIRE integration
- VirtualService is Alpha/TP

> Source: istio.io - Sidecar or ambient?; docs.redhat.com SM3 3.3

### 12.4 Rollback

As a new cluster, rollback consists of **not cutting over** to the new cluster and keeping the source cluster with SM3 sidecar active. The destination cluster can be destroyed and recreated if needed.

If sidecar mode is needed again on the same new cluster:
1. Switch to the branch/directory in the repo with sidecar manifests
2. ArgoCD will synchronize the state — restoring `istio-injection: enabled` labels, removing ztunnel, etc.
3. Pods will be recreated with sidecar injected

> Source: istio.io - Enable ambient mode

---



*Document generated on July 14, 2026 based exclusively on official Red Hat documentation (docs.redhat.com) and upstream Istio (istio.io).*
