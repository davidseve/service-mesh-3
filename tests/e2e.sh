#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-mesh-apps}"
BOOKINFO_NS="${BOOKINFO_NS:-bookinfo}"
PASSED=0
FAILED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

run_test() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))

  if [[ "$actual" == *"$expected"* ]]; then
    echo -e "  ${GREEN}PASS${NC} [$TOTAL] $name"
    PASSED=$((PASSED + 1))
  else
    echo -e "  ${RED}FAIL${NC} [$TOTAL] $name"
    echo -e "       Expected: ${CYAN}$expected${NC}"
    echo -e "       Got:      ${CYAN}$actual${NC}"
    FAILED=$((FAILED + 1))
  fi
}

exec_in_pod() {
  local deploy="$1"
  shift
  oc exec -n "$NAMESPACE" "deployment/$deploy" -- "$@" 2>/dev/null
}

http_code_from() {
  local deploy="$1"
  local url="$2"
  local result
  result=$(exec_in_pod "$deploy" curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null) || true
  echo "${result:-000}"
}

body_from() {
  local deploy="$1"
  local url="$2"
  local result
  result=$(exec_in_pod "$deploy" curl -s --max-time 5 "$url" 2>/dev/null) || true
  echo "${result:-CONNECTION_FAILED}"
}

echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   Service Mesh 3 Ambient Mode PoC -- E2E Test Suite     ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 1. Control Plane Health ──${NC}"
# ─────────────────────────────────────────────────────────

ISTIO_STATE=$(oc get istio default -o jsonpath='{.status.state}' 2>/dev/null || echo "NOT_FOUND")
run_test "Istio CR is Healthy" "Healthy" "$ISTIO_STATE"

CNI_STATE=$(oc get istiocni default -o jsonpath='{.status.state}' 2>/dev/null || echo "NOT_FOUND")
run_test "IstioCNI CR is Healthy" "Healthy" "$CNI_STATE"

ZT_STATE=$(oc get ztunnel default -o jsonpath='{.status.state}' 2>/dev/null || echo "NOT_FOUND")
run_test "ZTunnel CR is Healthy" "Healthy" "$ZT_STATE"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 2. Pod Readiness ──${NC}"
# ─────────────────────────────────────────────────────────

for deploy in app-a app-b app-c traffic-generator waypoint; do
  READY=$(oc get deployment "$deploy" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  run_test "Deployment $deploy has ready replicas" "1" "${READY:-0}"
done

GW_PODS=$(oc get pods -n "$NAMESPACE" -l gateway.networking.k8s.io/gateway-name -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null)
GW_COUNT=$(echo "$GW_PODS" | grep -c "Running" 2>/dev/null || echo "0")
run_test "Gateway pods running (>=2)" "true" "$([ "$GW_COUNT" -ge 2 ] && echo true || echo false)"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 3. Ambient Mesh Enrollment ──${NC}"
# ─────────────────────────────────────────────────────────

NS_LABEL=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || echo "NOT_SET")
run_test "Namespace has ambient dataplane label" "ambient" "$NS_LABEL"

for svc in backend app-b app-c; do
  WP_LABEL=$(oc get service "$svc" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null || echo "NOT_SET")
  run_test "Service $svc has waypoint label" "waypoint" "$WP_LABEL"
done

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 4. Gateway API Resources ──${NC}"
# ─────────────────────────────────────────────────────────

for gw in app-gateway-aws app-gateway-ocp waypoint; do
  PROGRAMMED=$(oc get gateway "$gw" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "NOT_FOUND")
  run_test "Gateway $gw is Programmed" "True" "$PROGRAMMED"
done

ROUTE_COUNT=$(oc get httproute -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
run_test "HTTPRoutes exist (>=3)" "true" "$([ "$ROUTE_COUNT" -ge 3 ] && echo true || echo false)"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 5. Internal Connectivity (from traffic-generator) ──${NC}"
# ─────────────────────────────────────────────────────────

CODE=$(http_code_from traffic-generator "http://app-a:8080/")
run_test "traffic-generator -> app-a:8080/ returns 200" "200" "$CODE"

CODE=$(http_code_from traffic-generator "http://app-a:8080/healthz")
run_test "traffic-generator -> app-a:8080/healthz returns 200" "200" "$CODE"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 6. Waypoint L7 Routing (app-a -> backend -> app-b/app-c) ──${NC}"
# ─────────────────────────────────────────────────────────

BODY=$(body_from app-a "http://backend:8080/app-b")
run_test "app-a -> backend/app-b routed to App B" '"app":"app-b"' "$BODY"

BODY=$(body_from app-a "http://backend:8080/app-c")
run_test "app-a -> backend/app-c routed to App C" '"app":"app-c"' "$BODY"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 7. Nginx Reverse Proxy (app-a proxies to backend via waypoint) ──${NC}"
# ─────────────────────────────────────────────────────────

BODY=$(body_from traffic-generator "http://app-a:8080/app-b")
run_test "traffic-gen -> app-a/app-b proxied to App B" '"app":"app-b"' "$BODY"

BODY=$(body_from traffic-generator "http://app-a:8080/app-c")
run_test "traffic-gen -> app-a/app-c proxied to App C" '"app":"app-c"' "$BODY"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 7b. Waypoint RequestHeaderModifier (Gateway API L7 headers) ──${NC}"
# ─────────────────────────────────────────────────────────

BODY=$(body_from app-a "http://backend:8080/app-b")
run_test "Header x-routed-by arrives at app-b" '"x-routed-by":"sm3-waypoint"' "$BODY"
run_test "Header x-destination arrives at app-b" '"x-destination":"app-b"' "$BODY"
run_test "Header x-mesh-trace-id arrives at app-b" '"x-mesh-trace-id":"poc-trace-app-b"' "$BODY"

BODY=$(body_from app-a "http://backend:8080/app-c")
run_test "Header x-routed-by arrives at app-c" '"x-routed-by":"sm3-waypoint"' "$BODY"
run_test "Header x-destination arrives at app-c" '"x-destination":"app-c"' "$BODY"
run_test "Header x-mesh-trace-id arrives at app-c" '"x-mesh-trace-id":"poc-trace-app-c"' "$BODY"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 8. External Ingress via OCP Route ──${NC}"
# ─────────────────────────────────────────────────────────

OCP_HOST=$(oc get route app-a -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$OCP_HOST" ]]; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$OCP_HOST/" 2>/dev/null || echo "000")
  run_test "External: OCP Route -> app-a returns 200" "200" "$CODE"

  BODY=$(curl -s --max-time 10 "http://$OCP_HOST/app-b" 2>/dev/null || echo "FAILED")
  run_test "External: OCP Route -> /app-b returns App B JSON" '"app":"app-b"' "$BODY"

  BODY=$(curl -s --max-time 10 "http://$OCP_HOST/app-c" 2>/dev/null || echo "FAILED")
  run_test "External: OCP Route -> /app-c returns App C JSON" '"app":"app-c"' "$BODY"
else
  run_test "External: OCP Route exists" "found" "NOT_FOUND"
fi

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 9. External Ingress via AWS Gateway (LoadBalancer) ──${NC}"
# ─────────────────────────────────────────────────────────

AWS_SVC_TYPE=$(oc get service app-gateway-aws-istio -n "$NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || echo "NOT_FOUND")
run_test "AWS Gateway Service type is LoadBalancer" "LoadBalancer" "$AWS_SVC_TYPE"

OCP_SVC_TYPE=$(oc get service app-gateway-ocp-istio -n "$NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || echo "NOT_FOUND")
run_test "OCP Gateway Service type is ClusterIP" "ClusterIP" "$OCP_SVC_TYPE"

AWS_ADDR=$(oc get gateway app-gateway-aws -n "$NAMESPACE" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
if [[ -n "$AWS_ADDR" ]]; then
  CODE="000"
  for attempt in 1 2 3 4 5; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$AWS_ADDR/" 2>/dev/null || echo "000")
    if [[ "$CODE" == "200" ]]; then
      break
    fi
    echo -e "       ${YELLOW}AWS ELB not ready (attempt $attempt/5, got $CODE), waiting 15s...${NC}"
    sleep 15
  done
  run_test "External: AWS Gateway -> app-a returns 200" "200" "$CODE"
else
  run_test "External: AWS Gateway has address" "found" "NOT_FOUND"
fi

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 10. Security: AuthorizationPolicy Enforcement ──${NC}"
# ─────────────────────────────────────────────────────────

CODE=$(http_code_from traffic-generator "http://backend:8080/app-b")
run_test "DENY: traffic-gen -> backend (not allowed by ALLOW policy)" "403" "$CODE"

CODE=$(http_code_from traffic-generator "http://app-b:8080/")
run_test "DENY: traffic-gen -> app-b direct (deny-bypass blocks)" "403" "$CODE"

CODE=$(http_code_from traffic-generator "http://app-c:8080/")
run_test "DENY: traffic-gen -> app-c direct (deny-bypass blocks)" "403" "$CODE"

CODE=$(http_code_from app-a "http://app-b:8080/app-b")
run_test "ALLOW: app-a -> app-b via waypoint (allowed)" "200" "$CODE"

CODE=$(http_code_from app-a "http://app-c:8080/app-c")
run_test "ALLOW: app-a -> app-c via waypoint (allowed)" "200" "$CODE"

CODE=$(http_code_from app-b "http://app-c:8080/")
run_test "DENY: app-b -> app-c (not in ALLOW rules)" "403" "$CODE"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 11. Security: mTLS & AuthorizationPolicy Count ──${NC}"
# ─────────────────────────────────────────────────────────

# PeerAuthentication STRICT is redundant in ambient mode: ztunnel always
# enforces mTLS via HBONE regardless of PeerAuthentication resources (ADR-0008).
# We validate that AuthorizationPolicies are deployed instead.

POLICY_COUNT=$(oc get authorizationpolicy -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
run_test "AuthorizationPolicies exist (>=5)" "true" "$([ "$POLICY_COUNT" -ge 5 ] && echo true || echo false)"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 12. Observability Components ──${NC}"
# ─────────────────────────────────────────────────────────

KIALI_READY=$(oc get deployment kiali -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
run_test "Kiali deployment is ready" "1" "${KIALI_READY:-0}"

OTEL_READY=$(oc get deployment otel-collector-collector -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
run_test "OTEL Collector deployment is ready" "1" "${OTEL_READY:-0}"

TEMPO_READY=$(oc get statefulset tempo-tempo -n tempo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
run_test "Tempo statefulset is ready" "1" "${TEMPO_READY:-0}"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 13. Traffic Generator Producing Traffic ──${NC}"
# ─────────────────────────────────────────────────────────

TG_LOGS=$(oc logs deployment/traffic-generator -n "$NAMESPACE" --tail=6 2>/dev/null || echo "NO_LOGS")
TG_200=$(echo "$TG_LOGS" | grep -c "200" || true)
TG_200=${TG_200:-0}
run_test "Traffic generator producing 200s (recent logs)" "true" "$([ "$TG_200" -ge 3 ] 2>/dev/null && echo true || echo false)"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 14. Bookinfo: Namespace & Ambient Enrollment ──${NC}"
# ─────────────────────────────────────────────────────────

BI_NS_LABEL=$(oc get namespace "$BOOKINFO_NS" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || echo "NOT_SET")
run_test "Bookinfo namespace has ambient label" "ambient" "$BI_NS_LABEL"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 15. Bookinfo: Pod Readiness ──${NC}"
# ─────────────────────────────────────────────────────────

for deploy in details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 productpage-v1; do
  READY=$(oc get deployment "$deploy" -n "$BOOKINFO_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  run_test "Bookinfo deployment $deploy has ready replicas" "1" "${READY:-0}"
done

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 16. Bookinfo: Waypoint Gateway ──${NC}"
# ─────────────────────────────────────────────────────────

BI_WP_PROG=$(oc get gateway waypoint -n "$BOOKINFO_NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "NOT_FOUND")
run_test "Bookinfo waypoint is Programmed" "True" "$BI_WP_PROG"

BI_WP_LABEL=$(oc get service reviews -n "$BOOKINFO_NS" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}' 2>/dev/null || echo "NOT_SET")
run_test "Bookinfo reviews service has waypoint label" "waypoint" "$BI_WP_LABEL"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 17. Bookinfo: HTTPRoute Traffic Split ──${NC}"
# ─────────────────────────────────────────────────────────

BI_ROUTE=$(oc get httproute reviews -n "$BOOKINFO_NS" -o jsonpath='{.spec.rules[0].backendRefs[*].name}' 2>/dev/null || echo "NOT_FOUND")
run_test "Bookinfo HTTPRoute reviews exists with backends" "reviews-v1" "$BI_ROUTE"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 18. Bookinfo: Productpage Connectivity ──${NC}"
# ─────────────────────────────────────────────────────────

bi_http_code() {
  local url="$1"
  local result
  result=$(oc exec -n "$BOOKINFO_NS" deployment/productpage-v1 -- \
    python3 -c "import urllib.request; r=urllib.request.urlopen('$url'); print(r.getcode())" 2>/dev/null) || result="000"
  echo "${result:-000}"
}

BI_CODE=$(bi_http_code "http://productpage:9080/productpage")
run_test "Bookinfo productpage -> /productpage returns 200" "200" "$BI_CODE"

BI_CODE=$(bi_http_code "http://details:9080/details/0")
run_test "Bookinfo productpage -> details returns 200" "200" "$BI_CODE"

BI_CODE=$(bi_http_code "http://reviews:9080/reviews/0")
run_test "Bookinfo productpage -> reviews returns 200" "200" "$BI_CODE"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${CYAN}── 19. Bookinfo: Traffic Split Verification ──${NC}"
# ─────────────────────────────────────────────────────────

SPLIT_SAMPLES=40
V1_COUNT=0
V2_COUNT=0
OTHER_COUNT=0
for i in $(seq 1 $SPLIT_SAMPLES); do
  POD_NAME=$(oc exec -n "$BOOKINFO_NS" deployment/productpage-v1 -- \
    python3 -c "
import urllib.request, json
r = urllib.request.urlopen('http://reviews:9080/reviews/0')
d = json.loads(r.read().decode())
print(d.get('podname','unknown'))
" 2>/dev/null) || POD_NAME="error"
  if echo "$POD_NAME" | grep -q "reviews-v2"; then
    V2_COUNT=$((V2_COUNT + 1))
  elif echo "$POD_NAME" | grep -q "reviews-v3"; then
    OTHER_COUNT=$((OTHER_COUNT + 1))
  else
    V1_COUNT=$((V1_COUNT + 1))
  fi
done
run_test "Bookinfo traffic split: v1 gets majority (>20/$SPLIT_SAMPLES)" "true" "$([ "$V1_COUNT" -gt 20 ] && echo true || echo false)"
run_test "Bookinfo traffic split: v2 gets some traffic (>0/$SPLIT_SAMPLES)" "true" "$([ "$V2_COUNT" -gt 0 ] && echo true || echo false)"
echo -e "       ${CYAN}Distribution: v1=$V1_COUNT, v2=$V2_COUNT, v3=$OTHER_COUNT (out of $SPLIT_SAMPLES)${NC}"

echo ""

# ─────────────────────────────────────────────────────────
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "  Total: $TOTAL | ${GREEN}Passed: $PASSED${NC} | ${RED}Failed: $FAILED${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
