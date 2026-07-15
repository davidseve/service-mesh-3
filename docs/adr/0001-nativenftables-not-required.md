# ADR-0001: nativeNftables not required on this cluster

## Status

Accepted

## Context

OpenShift Service Mesh 3 in ambient mode requires setting `spec.values.global.nativeNftables: true` on the Istio and IstioCNI resources **only** when the cluster has nodes running RHEL 10 or RHCOS 10. These systems use nftables as the default firewall backend, replacing iptables.

Our OCP 4.20.8 cluster on AWS runs RHCOS 9.4 (based on RHEL 9.4), which uses iptables as the firewall backend. This was verified by connecting to a worker node:

```
ID="rhel"
VERSION_ID="9.4"
```

## Options Considered

### Option 1: Do not configure nativeNftables (chosen)
- **Pros:** Simpler configuration. Avoids enabling functionality that does not apply to the current operating system.
- **Cons:** If nodes are migrated to RHCOS 10 in the future, the Istio and IstioCNI CRs will need to be updated.

### Option 2: Configure nativeNftables: true proactively
- **Pros:** Prepared for a future migration to RHCOS 10.
- **Cons:** Not documented or tested for RHCOS 9.x. Could cause unexpected behavior in ztunnel traffic redirection.

## Decision

Do not configure `nativeNftables: true` on the Istio or IstioCNI resources. The cluster runs RHCOS 9.4 and this option only applies to RHCOS 10 / RHEL 10.

## Consequences

### Positive
- Clean configuration aligned with official documentation for RHCOS 9.x.
- Lower risk of side effects in traffic redirection.

### Negative
- Requires review if the cluster is upgraded to a version with RHCOS 10 nodes.

### Neutral
- ztunnel traffic redirection works correctly using iptables on RHCOS 9.4.

## References

- [SM3 3.3 Installing - Istio ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-istio-ambient-mode): "Add this line if deploying on RHEL 10 or RHCOS 10 nodes"
- [SM3 3.3 Installing - Istio resource](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-installing-service-mesh): nativeNftables field documentation
