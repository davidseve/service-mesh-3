# service-mesh-3

OpenShift Service Mesh 3 **ambient mode** learning PoC. Helm charts by domain, orchestrated with `Makefile`.

**Requirements:** OCP 4.19+, `oc` logged in as cluster-admin, `helm`, `make`, `curl`.

## Deploy

Full stack (OVN patch → operators → mesh → apps → gateways → security → observability → bookinfo → smoke tests):

```bash
make deploy-all
```

Run phases individually if needed:

```bash
make configure-ovn          # ADR-0002: routingViaHost=true
make install-operators wait-operators
make deploy-mesh wait-mesh
make deploy-apps wait-apps
make deploy-gateways
make deploy-security
make deploy-observability
make deploy-bookinfo wait-bookinfo
```

Validate:

```bash
make test          # quick ingress + mesh checks
make test-e2e      # full ambient PoC test suite
```

Cleanup:

```bash
make clean         # removes all PoC resources
```

Charts live under `charts/` (operators, control-plane, apps, gateway-routing, security, observability, bookinfo).

## Observability URLs

| Tool | URL | Notes |
|------|-----|-------|
| **Traces (primary)** | `https://<console-host>/observe/traces` | COO Distributed Tracing UIPlugin; select Tempo instance `tempo` and tenant `dev` |
| **Kiali** | `oc get route kiali -n istio-system` | Traffic graph, mesh topology, mTLS |
| **Apps (ingress)** | `oc get route app-a -n mesh-apps` | PoC frontend via OCP Route |

Get the console host:

```bash
oc get route console -n openshift-console -o jsonpath='https://{.spec.host}/observe/traces{"\n"}'
```

Standalone Jaeger UI is **disabled**; tracing uses multitenancy Tempo + OCP Console per [COO distributed tracing UI plugin](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/html/ui_plugins_for_red_hat_openshift_cluster_observability_operator/distributed-tracing-ui-plugin).

## Architecture decisions (ADRs)

All decisions are documented in [`docs/adr/`](docs/adr/). Read them in order for context, or jump to the topic you care about:

| ADR | Topic |
|-----|-------|
| [0001](docs/adr/0001-nativenftables-not-required.md) | `nativeNftables` not needed on RHCOS 9 |
| [0002](docs/adr/0002-ovn-routingviahost-required.md) | OVN `routingViaHost=true` prerequisite |
| [0003](docs/adr/0003-servicemeshoperator3-vs-sailoperator.md) | Red Hat operator vs community |
| [0004](docs/adr/0004-ambient-mode-vs-sidecar.md) | Ambient vs sidecar mode |
| [0005](docs/adr/0005-gateway-api-vs-istio-gateway.md) | Gateway API only (no VirtualService) |
| [0006](docs/adr/0006-dual-ingress-aws-lb-and-ocp-route.md) | AWS LoadBalancer + OCP Route |
| [0007](docs/adr/0007-waypoint-l7-path-routing.md) | Waypoint L7 path routing |
| [0008](docs/adr/0008-zero-trust-dual-enforcement.md) | ztunnel L4 + waypoint L7 security |
| [0009](docs/adr/0009-observability-stack-redhat.md) | Kiali, Tempo, OTEL, Loki stack |
| [0010](docs/adr/0010-helm-charts-separated-by-domain.md) | Helm chart layout |
| [0011](docs/adr/0011-nginx-apps-and-virtual-backend.md) | Demo apps + virtual backend |
| [0012](docs/adr/0012-ztunnel-waypoint-scalability.md) | ztunnel/waypoint scaling |
| [0013](docs/adr/0013-service-account-per-service-identity.md) | ServiceAccount per service |

Sidecar → ambient migration guide: [`docs/migration-sidecar-to-ambient.md`](docs/migration-sidecar-to-ambient.md).

Agent/project context for Cursor: [`AGENTS.md`](AGENTS.md).
