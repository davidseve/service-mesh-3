# ADR-0012: ztunnel and waypoint scalability in ambient mode

## Status

Accepted

## Context

In an enterprise scenario with ~300 applications per namespace and up to 8000 applications cluster-wide, it is necessary to evaluate how the two ambient mode data plane components scale:

1. **ztunnel (L4)**: DaemonSet with one pod per node. Manages mTLS, HBONE tunneling, and L4 policies for **all** pods on the node. Cannot scale independently of the number of nodes.
2. **waypoint (L7)**: Envoy Deployment per namespace (or per service). Manages HTTP routing, traffic splitting, retries, and L7 policies. Can scale like any Kubernetes Deployment.

The main risk is not the number of applications (ztunnel is designed for 100K+ pods), but **traffic density per node** and correct horizontal scaling configuration for waypoints.

## Options Considered

### Option 1: Namespace waypoint with HPA + ztunnel tuning (chosen)
- **Pros:** Lower operational complexity. HPA scales waypoints automatically. discoverySelectors limits control plane blast radius. Per-service waypoints available for critical services.
- **Cons:** One namespace with 300 apps shares a waypoint; possible noisy-neighbor if one app generates disproportionate traffic.

### Option 2: Per-service waypoint for all apps
- **Pros:** Total isolation between services. Granular scaling.
- **Cons:** 8000 waypoints would consume massive resources. Operational overhead of managing thousands of Deployments + HPAs.

### Option 3: No waypoints (ztunnel L4 only)
- **Pros:** Minimum overhead. mTLS and L4 policies only.
- **Cons:** No L7 features (HTTP routing, header-based authz, traffic splitting, retries). Insufficient for the required architecture.

## Decision

Adopt a hybrid scaling model:

### ztunnel scaling

ZTunnel scales horizontally implicitly with the number of nodes (DaemonSet). Key optimizations:

**1. discoverySelectors (already implemented):**
Limits the namespaces istiod discovers, drastically reducing xDS configuration sent to each ztunnel. Without discoverySelectors, each proxy receives configuration for all cluster namespaces, including workloads not enrolled in the mesh:
```yaml
meshConfig:
  discoverySelectors:
  - matchLabels:
      istio-discovery: enabled
```
Source: [SM3 3.3 Installing sec. 4.3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)

**2. Delta xDS + On-Demand Discovery:**
ZTunnel uses optimized protocols built into its Rust implementation:
- **Delta xDS**: Receives only incremental changes, not full state. When a Deployment scales from 10 to 15 replicas, only the 5 new endpoints are sent.
- **On-Demand xDS**: When ztunnel receives traffic to an unknown IP, it queries istiod on demand instead of pre-loading all endpoints. Designed to support clusters with 1M+ endpoints.

Source: [Istio Architecture: ztunnel.md](https://github.com/istio/istio/blob/master/architecture/ambient/ztunnel.md)

**3. Purpose-built xDS API:**
Unlike Envoy sidecars (~350 lines of xDS per Service), ztunnel uses its own minimalist xDS protocol with native Rust types (`Address` and `Authorization`), with orders of magnitude less configuration. This allows configuring ztunnels efficiently for meshes with 100K pods.

Source: [Istio Blog: Rust-Based Ztunnel](https://istio.io/latest/blog/2023/rust-based-ztunnel/)

**4. Efficient certificate model:**
Ztunnel manages one certificate per ServiceAccount present on the node, not one per pod. With 100 pods from 10 distinct ServiceAccounts on a node, it only maintains 10 certificates. The CA rejects identity requests for workloads that do not run on that node, limiting the impact of a compromised node.

Source: [Istio Architecture: ztunnel.md](https://github.com/istio/istio/blob/master/architecture/ambient/ztunnel.md)

**5. Measured resource consumption (official Istio 1.24 benchmark):**
At 1000 rps with 1KB payload:

| Component | CPU | Memory |
|---|---|---|
| ztunnel | 0.06 vCPU | 12 MB |
| waypoint | 0.25 vCPU | 60 MB |
| sidecar | 0.20 vCPU | 60 MB |

ztunnel memory consumption depends on total configuration state (workloads, services, policies). CPU scales with traffic volume.

Source: [Istio Performance and Scalability](https://istio.io/latest/docs/ops/deployment/performance-and-scalability/)

**6. Concurrency (worker threads):**
Istio automatically configures the `concurrency` parameter based on the container CPU limit. For example, a 2500m limit assigns 3 workers. For manual adjustment, configure it in the Istio CR, not via environment variables.

Source: [OCP 4.21 Service Mesh docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/service_mesh/index)

> **CRITICAL**: Do not configure hard memory limits on ztunnel. If OOM-killed, all network connectivity on the node is lost.

### Waypoint scaling

**1. HPA on namespace waypoints:**
Waypoints are standard Kubernetes Deployments automatically generated from the Gateway resource. HPA can be applied by referencing the Deployment (not the Gateway):
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: waypoint-hpa
  namespace: mesh-apps
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: waypoint
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```
Source: [Istio: Configure waypoint proxies](https://istio.io/latest/docs/ambient/usage/waypoint/)

**2. PodDisruptionBudget for HA:**
Selected via the `gateway.networking.k8s.io/gateway-name` label automatically generated by Istio:
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: waypoint-pdb
  namespace: mesh-apps
spec:
  minAvailable: 1
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: waypoint
```
Source: [Istio: Configure waypoint proxies](https://istio.io/latest/docs/ambient/usage/waypoint/)

**3. TopologySpreadConstraints for multi-zone:**
To distribute waypoint replicas across availability zones, two officially documented mechanisms exist:
- **Per-Gateway**: use `infrastructure.parametersRef` on the Gateway pointing to a ConfigMap in the same namespace with key `deployment` containing a strategic merge patch.
- **Per-GatewayClass (global)**: create a ConfigMap with label `gateway.istio.io/defaults-for-class: istio-waypoint` in the `istio-system` namespace. Applies to all waypoints in the cluster as defaults.

In both cases, the ConfigMap uses this format:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: waypoint-options
data:
  deployment: |
    spec:
      template:
        spec:
          topologySpreadConstraints:
          - maxSkew: 1
            topologyKey: topology.kubernetes.io/zone
            whenUnsatisfiable: DoNotSchedule
            labelSelector:
              matchLabels:
                gateway.networking.k8s.io/gateway-name: waypoint
```

Source: [Istio: Kubernetes Gateway API - Automated Deployment](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#automated-deployment)

> **Note**: The `gateway.istio.io/deployment-topology-spread-constraints` annotation referenced in some third-party blogs is not part of the official Istio API. Similarly, the Helm value `pilot.waypoint.topologySpreadConstraints` ([PR #52919](https://github.com/istio/istio/pull/52919)) has partial support and is not documented as a user-facing mechanism; prefer the ConfigMap with `parametersRef`.

**4. Default waypoint resources (upstream Helm chart):**

| Field | Value |
|---|---|
| CPU request | 100m |
| Memory request | 128Mi |
| CPU limit | 2 |
| Memory limit | 1Gi |

Source: [istio/istio values.yaml - pilot.waypoint.resources](https://github.com/istio/istio/blob/master/manifests/charts/istio-control/istio-discovery/values.yaml)

**5. Per-service waypoints for critical services:**
High-traffic services can have a dedicated waypoint via the `istio.io/use-waypoint` label on the Service, avoiding the noisy-neighbor problem:
```yaml
kubectl label service critical-svc istio.io/use-waypoint=critical-svc-waypoint
```
Source: [SM3 3.3 Installing sec. 4.7](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode), [Istio: Configure waypoint proxies](https://istio.io/latest/docs/ambient/usage/waypoint/)

**6. Cross-namespace waypoints:**
A waypoint can be shared across namespaces by configuring `allowedRoutes.namespaces` on the Gateway and labels `istio.io/use-waypoint` + `istio.io/use-waypoint-namespace` on the consuming namespace. Useful for shared infrastructure waypoints.

Source: [SM3 3.3 Installing sec. 4.8](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)

### Control plane scaling (istiod)

Istiod is horizontally scalable. With 8000 apps, consider multiple replicas. The number of xDS clients in ambient mode is drastically reduced compared to sidecar mode: from one-per-pod (~8000) to one-per-node (ztunnels) + waypoints. istiod CPU scales with the rate of deployment changes, configuration, and the number of connected proxies.

Source: [Istio Performance and Scalability](https://istio.io/latest/docs/ops/deployment/performance-and-scalability/)

### Not all namespaces need a waypoint

If a namespace only needs L4 (mTLS + identity-based AuthorizationPolicy), it does not require a waypoint. Deploy waypoints only where L7 features are needed (HTTP routing, header-based authz, traffic splitting, retries).

Source: [SM3 3.3 Installing sec. 4.5](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode)

### ztunnel upgrade considerations

Ztunnel cannot transfer connection state to another process. Updating the DaemonSet affects all traffic on at least one node at a time. Configure a high `terminationGracePeriodSeconds` on the ZTunnel CR so active connections close gracefully.

Source: [SM3 3.3 Updating sec. 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/updating/ossm-updating-openshift-service-mesh-in-ambient-mode)

## Consequences

### Positive
- 8000 apps are well below ztunnel architectural limits (designed for 100K+ pods).
- discoverySelectors already reduces control plane load by sending xDS only for mesh namespaces.
- Waypoints scale horizontally with HPA without manual intervention.
- The hybrid model (namespace-level + per-service for critical) balances simplicity and isolation.
- The number of xDS clients drops from ~8000 (sidecar mode) to dozens (ztunnels + waypoints).
- ztunnel resource consumption (0.06 vCPU, 12MB at 1000 rps) is significantly lower than sidecars (0.20 vCPU, 60MB).

### Negative
- Known ztunnel concurrency limitation (SM3 3.2 release notes, OSSM-11132): limits throughput under extreme load on a single node. Performance comparable to sidecar mode but not superior.
- Traffic hot-spots require pod anti-affinity to distribute high-traffic apps across nodes.
- HPA and PDB must be created and maintained for each namespace with a waypoint.
- ztunnel upgrades affect all traffic on the node; require a maintenance window or per-node drain strategy.

### Neutral
- Concern thresholds are well above the current scenario: >100K pods, >20K services, >20K concurrent connections per node.
- ztunnel evolution (75% throughput improvements in the last 4 Istio releases) indicates limits will continue to expand.

## References

Primary sources (Red Hat docs):
- [SM3 3.3 Installing sec. 4](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): discoverySelectors, waypoint deployment, cross-namespace waypoints, authorization policies
- [SM3 3.3 Updating sec. 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/updating/ossm-updating-openshift-service-mesh-in-ambient-mode): ztunnel upgrade, terminationGracePeriodSeconds
- [SM3 3.2 Release Notes sec. 1.9.2](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/release_notes/ossm-release-notes): "Limitation due to ztunnel concurrency issue" (OSSM-11132)
- [Red Hat Blog: Introducing SM3 3.2](https://www.redhat.com/en/blog/introducing-openshift-service-mesh-32-istios-ambient-mode): "ambient mode's architecture offers the potential to scale to tens or even hundreds of thousands of workloads"
- [OCP 4.21 Service Mesh docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/service_mesh/index): concurrency parameter based on CPU limits

Secondary sources (upstream Istio):
- [Istio Performance and Scalability](https://istio.io/latest/docs/ops/deployment/performance-and-scalability/): benchmark data (1000 services, 2000 pods, 70K rps)
- [Istio: Configure waypoint proxies](https://istio.io/latest/docs/ambient/usage/waypoint/): HPA, PDB, per-service waypoints
- [Istio Architecture: ztunnel.md](https://github.com/istio/istio/blob/master/architecture/ambient/ztunnel.md): Delta xDS, on-demand discovery, certificate model, 1M endpoint support
- [Istio Blog: Rust-Based Ztunnel](https://istio.io/latest/blog/2023/rust-based-ztunnel/): purpose-built xDS, 100K pods with orders of magnitude less configuration
- [Istio Blog: Ambient Performance](https://istio.io/latest/blog/2025/ambient-performance/): "ztunnel performance has improved by 75% over 4 releases"
- [Istio: Kubernetes Gateway API](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/): infrastructure.parametersRef to customize waypoints
