---
name: redhat-source-of-truth
description: >-
  Enforce Red Hat official documentation as the primary source of truth for all
  OpenShift, Service Mesh, Istio, Kubernetes, and RHEL-related work. Use when
  generating YAML manifests, Helm charts, operator configurations, CRDs, API
  references, or troubleshooting OCP/SM3/Istio/K8s. Activates on any context
  involving Red Hat, OpenShift, OCP, Service Mesh, Istio, ztunnel, waypoint,
  Gateway API, Kiali, Tempo, Loki, OTEL, Helm on OCP, or oc/kubectl commands.
---

# Red Hat Documentation as Source of Truth

## Trust Hierarchy

When generating configuration, manifests, or advice for Red Hat technologies, follow this strict priority order:

1. **Red Hat official docs** (`docs.redhat.com`) -- always the primary source of truth
2. **Upstream OSS project docs** (istio.io, kubernetes.io, gateway-api.sigs.k8s.io) -- secondary, only when Red Hat docs lack coverage
3. **Red Hat blogs** (redhat.com/en/blog) -- supplementary context for new features
4. **Community blogs and articles** -- reference only, never as a sole basis for configuration
5. **Model training knowledge** -- last resort, must be flagged as unverified

## Anti-Hallucination Rules

### Before generating any YAML manifest:
- Verify the `apiVersion` against Red Hat docs for the specific product version in use
- Verify CRD `kind` names are exact (e.g., `Istio` not `IstioMesh`, `ZTunnel` not `Ztunnel` for the CR)
- Verify field paths exist in the documented spec (e.g., `spec.values.pilot.trustedZtunnelNamespace`)
- Never invent fields, flags, annotations, or labels without a documented source

### When uncertain:
- Use `WebSearch` to query `site:docs.redhat.com` for the specific resource/field
- Use the `context7` MCP tool to fetch current library/framework docs
- Use the Red Hat KB skill if troubleshooting known issues
- State explicitly: "I could not verify this against Red Hat docs" when a claim lacks a source

### When citing information:
- Include the specific Red Hat doc URL for critical configuration decisions
- Reference the product version (e.g., "SM3 3.3", "OCP 4.20")
- If using upstream docs, note that the behavior may differ in the Red Hat distribution

## Key API Version Reference (SM3 on OCP 4.19+)

| Resource | apiVersion | Source |
|----------|-----------|--------|
| Istio | `sailoperator.io/v1` | SM3 3.3 Installing |
| IstioCNI | `sailoperator.io/v1` | SM3 3.3 Installing |
| ZTunnel | `sailoperator.io/v1alpha1` | SM3 3.3 Installing |
| Gateway | `gateway.networking.k8s.io/v1` | OCP 4.19+ built-in |
| HTTPRoute | `gateway.networking.k8s.io/v1` | OCP 4.19+ built-in |
| AuthorizationPolicy | `security.istio.io/v1` | SM3 3.3 Installing |
| PeerAuthentication | `security.istio.io/v1` | SM3 3.3 Installing |
| Subscription | `operators.coreos.com/v1alpha1` | OLM |
| OperatorGroup | `operators.coreos.com/v1` | OLM |
| Route | `route.openshift.io/v1` | OCP |

## Common Pitfalls to Avoid

- Do NOT use `sailoperator.io/v1alpha1` for Istio or IstioCNI (upgraded to `v1`)
- Do NOT use `security.istio.io/v1beta1` for AuthorizationPolicy (upgraded to `v1` in SM3 3.3+)
- Do NOT use VirtualService in ambient mode (Technology Preview, not GA)
- Do NOT omit `profile: ambient` on Istio, IstioCNI, and ZTunnel CRs when targeting ambient mode
- Do NOT forget `routingViaHost: true` prerequisite for ambient mode on OCP
