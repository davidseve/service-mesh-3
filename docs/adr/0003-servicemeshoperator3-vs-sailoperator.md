# ADR-0003: servicemeshoperator3 vs sailoperator

## Status

Accepted

## Context

To deploy OpenShift Service Mesh 3, two operators are available in the cluster OperatorHub:

- `servicemeshoperator3` (Red Hat Operators): Productized operator supported by Red Hat.
- `sailoperator` (Community Operators): Upstream community Istio operator.

Both manage the same CRDs (`Istio`, `IstioCNI`, `ZTunnel` from the `sailoperator.io` group), but they have different levels of support, testing, and release cycles.

## Options Considered

### Option 1: servicemeshoperator3 (Red Hat Operators) -- chosen
- **Pros:** Full Red Hat support. Tested and certified for OCP. Red Hat-maintained Istio distribution with OpenSSL for FIPS. Updates coordinated with OCP release cycles. `stable` channel with tested GA versions.
- **Cons:** May lag slightly behind the latest upstream Istio version.

### Option 2: sailoperator (Community Operators)
- **Pros:** Access to the latest Istio versions. Useful for development and experimentation with upstream features.
- **Cons:** **Not supported by Red Hat.** No OCP compatibility guarantees. No FIPS certification. Not for production use.

## Decision

Use `servicemeshoperator3` from the Red Hat Operators catalog, `stable` channel (v3.4.0). It is the only supported operator for Service Mesh 3 deployments on OpenShift.

SM3 is based on the upstream sail-operator project (`istio-ecosystem/sail-operator`), but the productized operator is built, tested, and distributed separately with the `quay.io/maistra-dev/sail-operator` image and Red Hat certifications.

## Consequences

### Positive
- Full Red Hat support for troubleshooting and updates.
- Guaranteed compatibility with the cluster OCP version (4.20).
- OpenSSL in ztunnel to meet FIPS requirements.

### Negative
- The embedded Istio version may not be the latest upstream release.

### Neutral
- The APIs (`sailoperator.io/v1`) are identical between both operators.

## References

- [Blog: Introducing Red Hat OpenShift Service Mesh 3](https://www.redhat.com/en/blog/introducing-red-hat-openshift-service-mesh-3): "OpenShift Service Mesh 3.0 is based on Istio 1.24... using a new operator based on the community sail-operator"
- [SM3 3.3 Installing](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-installing-service-mesh): Installation instructions reference the Red Hat operator
