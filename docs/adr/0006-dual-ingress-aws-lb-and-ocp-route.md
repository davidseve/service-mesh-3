# ADR-0006: Dual ingress -- AWS LoadBalancer + OCP Route

## Status

Accepted

## Context

To expose mesh services externally, there are two approaches with Gateway API:

1. **LoadBalancer Service** (default): Istio automatically creates a `LoadBalancer` Service for each Gateway with `gatewayClassName: istio`. On AWS, this provisions an Elastic Load Balancer (ELB). The `networking.istio.io/service-type: LoadBalancer` annotation is redundant but explicit.

2. **OpenShift Route**: The Service is forced to `ClusterIP` with the `networking.istio.io/service-type: ClusterIP` annotation and a native OpenShift `Route` is created pointing to the gateway Service, exposing the application through the OCP router.

> **Note (empirically verified 2025-07-13):** Both in upstream Istio and Red Hat OpenShift Service Mesh 3.3, the default type of the auto-generated Service is `LoadBalancer`, not `ClusterIP`. Red Hat documentation shows an `oc patch` step to LoadBalancer, but that is due to the pedagogical flow of the example (verify internally first), not because the default is ClusterIP.

This PoC runs on AWS, but the educational goal is to demonstrate both patterns.

## Options Considered

### Option 1: LoadBalancer only (cloud-native)
- **Pros:** Simple. Single Gateway resource. Direct public IP/hostname.
- **Cons:** Only works in cloud. Does not demonstrate the on-premise pattern.

### Option 2: OCP Route only (on-premise)
- **Pros:** Works in any OCP environment. Leverages the existing router.
- **Cons:** Does not demonstrate cloud-native integration. The route adds an extra hop.

### Option 3: Both approaches in parallel (chosen)
- **Pros:** Maximum educational value: demonstrates cloud and on-premise patterns. Allows comparing both traffic flows in Kiali.
- **Cons:** More resources deployed. Two entry points to manage.

## Decision

Deploy two Gateways:
- **app-gateway-aws**: `gatewayClassName: istio` with `networking.istio.io/service-type: LoadBalancer` (explicit, although it is the default). Access via AWS ELB hostname.
- **app-gateway-ocp**: `gatewayClassName: istio` with `networking.istio.io/service-type: ClusterIP` (override required to avoid provisioning an ELB). Exposed via an OpenShift `Route` at `app-a.apps.ocp.sandbox1903.opentlc.com`.

## Consequences

### Positive
- Covers the two most common service exposure scenarios.
- Allows comparing traffic behavior through two different paths.
- Maximum educational value for the PoC.

### Negative
- One ELB in AWS for gateway-aws (gateway-ocp uses ClusterIP, no ELB).
- Two sets of HTTPRoutes to maintain.

### Neutral
- Both Gateways direct traffic to the same backend (App A).

## References

- [SM3 3.3 Gateways sec. 2.6](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-getting-traffic-into-a-mesh): Gateway API ingress in ambient mode with LoadBalancer
- [SM3 3.3 Gateways](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/gateways/ossm-getting-traffic-into-a-mesh): "Exposing a gateway to traffic outside the cluster using OpenShift Routes"
