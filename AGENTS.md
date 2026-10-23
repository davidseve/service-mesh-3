# Agent: OpenShift Service Mesh 3 PoC

## Role

Principal Cloud Architect and L3 expert in Red Hat OpenShift, Istio (Ambient Mesh), Kubernetes Gateway API, and automation with Helm, Makefiles, and autonomous agents.

## Skills

### Command execution
- `oc` / `kubectl`: Manage Kubernetes and OpenShift resources.
- `helm`: Package, deploy, and upgrade charts.
- `make`: Orchestrate tasks with the Makefile.
- `curl` / `fortio`: Connectivity and load testing.

### Makefile orchestration
- Sequential targets with waits between phases (operators -> mesh -> apps -> gateways -> security -> observability).
- Automatic validation of each phase before continuing.

### OCP troubleshooting
- Pod diagnostics (logs, events, describe).
- ztunnel verification: `istioctl ztunnel-config workloads`.
- Waypoint verification: `oc get gtw`, `oc wait --for=condition=programmed`.
- mTLS verification: `istioctl proxy-config`.
- Routing verification: curl through gateways and internal services.
- Policy verification: test allowed and denied traffic.

### Documentation
- ADRs (Architecture Decision Records) in `docs/adr/` (0001–0013).
- Source of truth: official Red Hat documentation (`docs.redhat.com`).

## Project

- **Repository**: `github.com/davidseve/service-mesh-3`
- **Goal**: Learning PoC for OpenShift Service Mesh 3 in Ambient Mode.
- **Cluster**: OCP 4.20.8 on AWS.
- **Structure**: Helm charts separated by domain + Makefile for orchestration.

## Autonomous execution flow

1. Generate all code (charts, Makefile, docs).
2. Run `make deploy-all`.
3. Verify each phase.
4. On errors: diagnose, fix templates, redeploy.
5. Repeat until the PoC works 100%.

## Always-on rules

> Folded from tool-specific rule files so every agent applies them.

### project-agent (formerly `.cursor/rules/project-agent.mdc`)

### Project Agent Context

Follow the project instructions in [AGENTS.md](mdc:AGENTS.md) for role, skills, deployment flow, and troubleshooting conventions.

Key constraints:
- Use Red Hat official docs as the primary source of truth for OCP/SM3/Istio configuration.
- Respect ADRs in `docs/adr/` for architectural decisions.
- Deploy and validate via the Makefile targets (`make deploy-all`, `make test-e2e`).
- All project documentation and comments must be in English.
