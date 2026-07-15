#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Test: Verify Gateway Service type behavior in OpenShift SM3
#
# Validates ADR-0006 claims:
#   - A Gateway with networking.istio.io/service-type: LoadBalancer
#     produces a Service of type LoadBalancer
#   - A Gateway WITHOUT that annotation produces ClusterIP (Red Hat SM3 default)
#   - Optionally creates a temporary Gateway without annotation to confirm default
#
# Usage: ./tests/test-gateway-service-type.sh [--create-temp-gateway]
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${NAMESPACE:-mesh-apps}"
CREATE_TEMP="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0

assert() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}PASS${NC} $name"
    echo -e "       Value: ${CYAN}$actual${NC}"
    PASSED=$((PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC} $name"
    echo -e "       Expected: ${CYAN}$expected${NC}"
    echo -e "       Got:      ${CYAN}$actual${NC}"
    FAILED=$((FAILED + 1))
  fi
}

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Gateway Service Type Behavior Test (ADR-0006)          ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo ""

# ── Test 1: Gateway WITH annotation ──────────────────────
echo -e "${CYAN}── 1. Gateway with networking.istio.io/service-type: LoadBalancer ──${NC}"

AWS_GW_ANNOTATION=$(oc get gateway app-gateway-aws -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.networking\.istio\.io/service-type}' 2>/dev/null || echo "NOT_FOUND")
assert "Gateway app-gateway-aws has service-type annotation" "LoadBalancer" "$AWS_GW_ANNOTATION"

AWS_SVC_TYPE=$(oc get service app-gateway-aws-istio -n "$NAMESPACE" \
  -o jsonpath='{.spec.type}' 2>/dev/null || echo "NOT_FOUND")
assert "Service app-gateway-aws-istio is type LoadBalancer" "LoadBalancer" "$AWS_SVC_TYPE"

AWS_SVC_LB_INGRESS=$(oc get service app-gateway-aws-istio -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [[ -n "$AWS_SVC_LB_INGRESS" ]]; then
  echo -e "  ${GREEN}INFO${NC} ELB hostname: ${CYAN}${AWS_SVC_LB_INGRESS}${NC}"
  assert "Service has ELB hostname assigned" "true" "true"
else
  AWS_SVC_LB_IP=$(oc get service app-gateway-aws-istio -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "$AWS_SVC_LB_IP" ]]; then
    echo -e "  ${GREEN}INFO${NC} LB IP: ${CYAN}${AWS_SVC_LB_IP}${NC}"
    assert "Service has LB IP assigned" "true" "true"
  else
    assert "Service has external address (hostname or IP)" "assigned" "PENDING"
  fi
fi

echo ""

# ── Test 2: Gateway WITHOUT annotation (OCP) ─────────────
echo -e "${CYAN}── 2. Gateway without service-type annotation (default behavior) ──${NC}"

OCP_GW_ANNOTATION=$(oc get gateway app-gateway-ocp -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.networking\.istio\.io/service-type}' 2>/dev/null || echo "NOT_SET")
# If annotation is empty, it means it's not set (default)
OCP_GW_ANNOTATION="${OCP_GW_ANNOTATION:-NOT_SET}"
echo -e "  ${CYAN}INFO${NC} app-gateway-ocp service-type annotation: ${CYAN}${OCP_GW_ANNOTATION}${NC}"

OCP_SVC_TYPE=$(oc get service app-gateway-ocp-istio -n "$NAMESPACE" \
  -o jsonpath='{.spec.type}' 2>/dev/null || echo "NOT_FOUND")
echo -e "  ${CYAN}INFO${NC} app-gateway-ocp-istio Service.spec.type: ${CYAN}${OCP_SVC_TYPE}${NC}"

# The OCP gateway uses networking.istio.io/service-type: ClusterIP to override the default (LoadBalancer)
if [[ "$OCP_GW_ANNOTATION" == "ClusterIP" ]]; then
  assert "OCP Gateway Service is ClusterIP (annotation override)" "ClusterIP" "$OCP_SVC_TYPE"
elif [[ "$OCP_GW_ANNOTATION" == "NOT_SET" || "$OCP_GW_ANNOTATION" == "" ]]; then
  echo -e "  ${YELLOW}──── DEFAULT BEHAVIOR RESULT ────${NC}"
  echo -e "  ${YELLOW}Without annotation, Istio creates Service type: ${CYAN}${OCP_SVC_TYPE}${NC}"
  assert "OCP Gateway without annotation defaults to LoadBalancer" "LoadBalancer" "$OCP_SVC_TYPE"
else
  assert "OCP Gateway Service type matches annotation" "$OCP_GW_ANNOTATION" "$OCP_SVC_TYPE"
fi

echo ""

# ── Test 3 (optional): Create temp gateway to test true default ──
if [[ "$CREATE_TEMP" == "--create-temp-gateway" ]]; then
  echo -e "${CYAN}── 3. Temporary Gateway (no annotation) to confirm true default ──${NC}"
  TEMP_GW="test-default-svctype"

  oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${TEMP_GW}
  namespace: ${NAMESPACE}
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

  echo -e "  ${CYAN}INFO${NC} Waiting for service ${TEMP_GW}-istio to appear..."
  for i in $(seq 1 30); do
    TEMP_SVC_TYPE=$(oc get service "${TEMP_GW}-istio" -n "$NAMESPACE" \
      -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
    if [[ -n "$TEMP_SVC_TYPE" ]]; then
      break
    fi
    sleep 2
  done

  if [[ -n "$TEMP_SVC_TYPE" ]]; then
    echo -e "  ${YELLOW}══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${YELLOW}  DEFINITIVE ANSWER: Default Service type = ${CYAN}${TEMP_SVC_TYPE}${NC}"
    echo -e "  ${YELLOW}══════════════════════════════════════════════════════════${NC}"
    assert "Temp Gateway default Service type is LoadBalancer" "LoadBalancer" "$TEMP_SVC_TYPE"
  else
    echo -e "  ${RED}ERROR${NC} Service ${TEMP_GW}-istio did not appear after 60s"
    FAILED=$((FAILED + 1))
  fi

  echo -e "  ${CYAN}INFO${NC} Cleaning up temp gateway..."
  oc delete gateway "${TEMP_GW}" -n "$NAMESPACE" --ignore-not-found
  # Service is auto-deleted when gateway is removed
  sleep 5
  oc delete service "${TEMP_GW}-istio" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

  echo ""
fi

# ── Summary ───────────────────────────────────────────────
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Passed: $PASSED${NC} | ${RED}Failed: $FAILED${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
