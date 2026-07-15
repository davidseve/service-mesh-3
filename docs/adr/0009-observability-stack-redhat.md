# ADR-0009: Red Hat observability stack

## Status

Accepted

## Context

Ambient mode generates telemetry at two layers:
- **ztunnel (L4)**: TCP metrics (bytes, connections, duration). Does not generate distributed traces.
- **waypoint/gateway (L7)**: HTTP metrics, access logs, and **distributed traces** (spans).

To obtain full observability, we need: metrics (Prometheus), traces (Tempo + OTEL), logs (Loki), and a visual console (Kiali). Red Hat offers supported operators for each component.

## Options Considered

### Option 1: Full Red Hat stack (chosen)
- **Pros:** All components supported by Red Hat. Native OCP integration. Kiali has specific ambient mode support (visualizes ztunnel and waypoint). Documented in SM3 3.3 Observability.
- **Cons:** Multiple operators to install and configure.

### Option 2: OSS stack (Grafana + Jaeger + community Prometheus)
- **Pros:** Familiar to most Istio users.
- **Cons:** Not supported by Red Hat on OCP. Jaeger is deprecated in favor of Tempo. No native OCP monitoring integration.

## Decision

Install the full Red Hat stack:

| Component | Operator | Function |
|-----------|----------|----------|
| Kiali | `kiali-ossm` | Mesh topology, dashboards, validation |
| Tempo | `tempo-product` | Trace storage backend |
| OpenTelemetry | `opentelemetry-product` | Collector to gather and export traces |
| Cluster Observability | `cluster-observability-operator` | Tempo UIPlugin in the OCP console |
| Loki | `loki-operator` | Log aggregation |
| Prometheus/Thanos | Built-in OCP | Metrics (UserWorkloadMonitoring) |

The tracing pipeline is: waypoint/gateway -> OTEL Collector (istio-system) -> TempoStack (tempo namespace).

Kiali is configured with `external_services.tracing.provider: tempo` to show integrated traces.

## Consequences

### Positive
- End-to-end observability: L4 metrics (ztunnel), L7 metrics, traces, logs.
- Kiali shows mesh topology including waypoint nodes.
- All supported by Red Hat.

### Negative
- L7 tracing requires waypoint or gateway; ztunnel only generates L4 metrics.
- Multiple operators to manage.

### Neutral
- UserWorkloadMonitoring is already configured on most OCP clusters.

## References

- [SM3 3.3 Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html-single/observability/index): Full observability documentation
- [SM3 3.3 Observability - Tracing ambient mode](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/observability/distributed-tracing-and-service-mesh): sec. 3.1.3 "Configuring Tempo with Service Mesh ambient mode"
- [SM3 3.3 Observability - Kiali](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/observability/kiali-operator-provided-by-red-hat): Kiali ambient mode support
