# ADR-0002: OVN routingViaHost required for ambient mode

## Status

Accepted

## Context

Istio ambient mode deploys ztunnel as a per-node DaemonSet that intercepts all network traffic from pods enrolled in the mesh. ztunnel needs host-level access to traffic to redirect it correctly.

On OCP, OVN-Kubernetes has two gateway modes:
- **Shared** (default, `routingViaHost: false`): Egress traffic is processed in OVN/Open vSwitch (OVS) and exits directly to the node IP interface without passing through the host network stack.
- **Local** (`routingViaHost: true`): Egress traffic routes through the host kernel routing table. Host-to-pod traffic (including kubelet probes) can reach pods enrolled in ambient mode.

With `routingViaHost: false`, the kubelet cannot reach pods directly for liveness/readiness probes because ztunnel intercepts that traffic. This causes pods to enter `CrashLoopBackOff` or be marked as `NotReady`.

Our cluster had `routingViaHost: false` (the default value).

## Options Considered

### Option 1: Patch routingViaHost to true (chosen)
- **Pros:** Ambient mode works correctly. Kubelet probes reach pods. It is the only approach supported by Red Hat.
- **Cons:** Cluster-wide change affecting all nodes. Rolling restart of OVN pods (~5 min). Brief network interruption during rollout. Egress traffic no longer benefits from OVS hardware offloading.

### Option 2: Keep routingViaHost false
- **Pros:** No impact on the existing cluster.
- **Cons:** **Ambient mode is inoperable for workloads with HTTP probes.** Probes fail, pods do not start, the mesh does not work for those workloads. Removing probes is not a production workaround (validated in PoC only).

### Option 3: Use sidecar mode instead of ambient
- **Pros:** Does not require an OVN change. Sidecars do not depend on ztunnel.
- **Cons:** Fundamentally changes the PoC architecture. Higher resource consumption (sidecar per pod). Does not demonstrate ambient mode capabilities.

## Decision

Patch OVN-Kubernetes to use `routingViaHost: true`. It is a hard (not soft) prerequisite for ambient mode with HTTP liveness/readiness probes.

```bash
oc patch network.operator cluster --type=merge \
  -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
```

## PoC Validation (OCP 4.20.8)

Three configurations were tested on the same cluster:

| Configuration | HTTP Probes | routingViaHost | E2E Result |
|---------------|---------------|----------------|------------|
| Default | Enabled | `false` | 39/61 — apps in CrashLoopBackOff, probes timeout |
| Workaround | Disabled | `false` | 61/61 — full mesh works; probes are the only blocker |
| Production | Enabled | `true` | 61/61 — probes and full PoC pass |

**Key finding:** Without `routingViaHost`, only kubelet HTTP probes fail. Pod-to-pod mesh traffic, gateways, waypoint L7 routing, AuthorizationPolicy, observability, and Bookinfo all worked when probes were removed. Failures with probes enabled are a cascade: probe timeout → Not Ready → no Service Endpoints → 503 / connection reset.

## Consequences

### Positive
- Ambient mode works correctly: ztunnel intercepts traffic and probes reach pods.
- Aligned with official documentation and the only supported configuration.
- Custom host-level routes (`ip route`, node BGP, external NAT devices) now apply to pod egress traffic — useful for specialized egress topologies.
- Local gateway mode is a supported, production-grade OVN configuration (required on ppc64le).

### Negative

#### Operational
- Cluster-wide change: affects all namespaces and workloads, not just the mesh.
- Rolling restart of OVN pods (~5 min of minor interruption; observed ~30s on PoC cluster).
- Requires cluster-admin permissions.
- Change persists in `network.operator` and survives cluster upgrades.
- Reversing to `routingViaHost: false` requires another OVN rollout and breaks ambient probe reliability.

#### Performance
- Egress traffic is processed by the host networking stack instead of exiting directly from OVS.
- **OVS hardware offloading is not effective** when `routingViaHost: true` — Red Hat documents that offloading benefits are lost because egress bypasses the OVS fast path.
- Impact is negligible for typical application workloads and PoC scenarios. It matters in clusters with SmartNIC/offloading enabled or very high egress throughput requirements.

#### Routing behavior
- Pod egress traffic follows the **kernel routing table** of the node hosting the pod.
- In shared gateway mode (default), egress is handled entirely in OVN and is **not** affected by custom host routes.
- With local gateway mode, misconfigured node routes or host `iptables`/`nftables` rules can affect egress for all pods on that node.

### Neutral
- Existing TCP connections are re-established automatically after the OVN rollout.
- No measurable functional impact on workloads that do not use ambient mode.
- Internal pod-to-pod traffic, NetworkPolicies, EgressIP, EgressFirewall, Ingress, Routes, and LoadBalancers are not fundamentally changed.
- Does not require redeploying applications unrelated to the mesh.
- Does not change CNI plugin, MTU, Geneve port, or IPSec configuration.

### Not affected (common misconceptions)
- Workloads without the `istio.io/dataplane-mode: ambient` label continue to operate.
- Sidecar-mode Istio does not require this OVN change.
- Mesh control plane health (Istio, IstioCNI, ZTunnel CRs) is independent of this setting.

## References

- [OCP 4.20 — Configuring a gateway (OVN-Kubernetes)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/ovn-kubernetes_network_plugin/configuring-gateway): Shared vs local gateway mode, `routingViaHost` semantics
- [OCP 4.21 — Cluster Network Operator (`gatewayConfig`)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/networking_operators/cluster-network-operator): hardware offloading interaction with `routingViaHost`
- [SM3 3.2 Release Notes sec. 1.5.4](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html-single/release_notes/index): "Ensuring probe reliability with OVN-Kubernetes local gateway mode"
- [SM3 3.3 Installing - Ambient mode prerequisites](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "You have configured the OVN-Kubernetes CNI to use local gateway mode by setting the routingViaHost field as true"
- [SM3 3.1 Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/release_notes/ossm-release-notes): "pods that rely on liveness or readiness probes require you to set the OVN-Kubernetes gateway mode to local"
