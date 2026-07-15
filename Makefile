NAMESPACE := mesh-apps
ISTIO_NS := istio-system
TEMPO_NS := tempo
BOOKINFO_NS := bookinfo

.PHONY: deploy-all configure-ovn install-operators wait-operators deploy-mesh wait-mesh \
        deploy-apps wait-apps deploy-gateways deploy-security deploy-observability \
        deploy-bookinfo wait-bookinfo test test-e2e clean clean-bookinfo

deploy-all: configure-ovn install-operators wait-operators deploy-mesh wait-mesh \
            deploy-apps wait-apps deploy-gateways deploy-security deploy-observability \
            deploy-bookinfo wait-bookinfo test
	@echo "=== deploy-all complete ==="

# --- Phase 1: OVN Configuration ---
configure-ovn:
	@echo "=== Patching OVN routingViaHost=true (ADR-0002) ==="
	oc patch network.operator cluster --type=merge \
	  -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
	@echo "Waiting for OVN rollout (~5 min)..."
	sleep 30
	oc wait co/network --for=condition=Progressing=False --timeout=600s
	oc wait co/network --for=condition=Available=True --timeout=300s
	@echo "=== OVN patched ==="

# --- Phase 2: Operators ---
install-operators:
	@echo "=== Installing operators ==="
	helm upgrade --install operators charts/operators --wait --timeout 120s
	@echo "=== Operator subscriptions created ==="

wait-operators:
	@echo "=== Waiting for operator CSVs ==="
	@for op in servicemeshoperator3 kiali-operator cluster-observability-operator tempo-operator opentelemetry-operator; do \
	  echo "Waiting for $$op..."; \
	  timeout 300 bash -c "until oc get csv -n openshift-operators 2>/dev/null | grep -q \"$$op.*Succeeded\"; do sleep 10; done" || \
	    echo "WARNING: $$op not found or not Succeeded after 300s"; \
	done
	@echo "Waiting for loki-operator..."
	@timeout 300 bash -c 'until oc get csv -n openshift-operators-redhat 2>/dev/null | grep -q "loki-operator.*Succeeded"; do sleep 10; done' || \
	  echo "WARNING: loki-operator not found or not Succeeded after 300s"
	@echo "=== All operators ready ==="

# --- Phase 3: Service Mesh Control Plane ---
deploy-mesh:
	@echo "=== Deploying service mesh control plane ==="
	helm upgrade --install control-plane charts/control-plane --wait --timeout 120s
	@echo "=== Control plane deployed ==="

wait-mesh:
	@echo "=== Waiting for Istio, IstioCNI, ZTunnel ==="
	@timeout 300 bash -c 'until oc get istio default -o jsonpath="{.status.state}" 2>/dev/null | grep -q "Healthy"; do sleep 10; echo "Waiting for Istio..."; done'
	@timeout 300 bash -c 'until oc get istiocni default -o jsonpath="{.status.state}" 2>/dev/null | grep -q "Healthy"; do sleep 10; echo "Waiting for IstioCNI..."; done'
	@timeout 300 bash -c 'until oc get ztunnel default -o jsonpath="{.status.state}" 2>/dev/null | grep -q "Healthy"; do sleep 10; echo "Waiting for ZTunnel..."; done'
	@echo "=== Mesh control plane healthy ==="

# --- Phase 4: Applications ---
deploy-apps:
	@echo "=== Deploying applications ==="
	helm upgrade --install apps charts/apps --wait --timeout 120s
	@echo "=== Applications deployed ==="

wait-apps:
	@echo "=== Waiting for app pods ==="
	oc wait deployment -n $(NAMESPACE) app-a app-b app-c --for=condition=Available --timeout=180s
	@echo "=== All apps running ==="

# --- Phase 5: Gateway & Routing ---
deploy-gateways:
	@echo "=== Deploying gateways and routing ==="
	helm upgrade --install gateway-routing charts/gateway-routing --wait --timeout 120s
	@echo "Waiting for gateways to be programmed..."
	@timeout 120 bash -c 'until oc get gateway -n $(NAMESPACE) app-gateway-aws -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null | grep -q "True"; do sleep 5; done' || \
	  echo "WARNING: AWS gateway not programmed after 120s"
	@timeout 120 bash -c 'until oc get gateway -n $(NAMESPACE) app-gateway-ocp -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null | grep -q "True"; do sleep 5; done' || \
	  echo "WARNING: OCP gateway not programmed after 120s"
	@timeout 120 bash -c 'until oc get gateway -n $(NAMESPACE) waypoint -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null | grep -q "True"; do sleep 5; done' || \
	  echo "WARNING: Waypoint not programmed after 120s"
	@echo "=== Gateways and routing deployed ==="

# --- Phase 6: Security ---
deploy-security:
	@echo "=== Deploying security policies ==="
	helm upgrade --install security charts/security --wait --timeout 60s
	@echo "=== Security policies deployed ==="

# --- Phase 7: Observability ---
deploy-observability:
	@echo "=== Deploying observability stack ==="
	@CONSOLE_HOST=$$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null) && \
	  helm upgrade --install observability charts/observability --wait --timeout 120s \
	    --set coo.console.host=$$CONSOLE_HOST && \
	  echo "Tracing UI: https://$$CONSOLE_HOST/observe/traces"
	@echo "=== Observability deployed ==="

# --- Phase 8: Bookinfo Example ---
deploy-bookinfo:
	@echo "=== Deploying Bookinfo example ==="
	helm upgrade --install bookinfo charts/bookinfo --wait --timeout 180s
	@echo "=== Bookinfo deployed ==="

wait-bookinfo:
	@echo "=== Waiting for Bookinfo pods ==="
	oc wait deployment -n $(BOOKINFO_NS) details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 productpage-v1 \
	  --for=condition=Available --timeout=180s
	@echo "Waiting for bookinfo waypoint..."
	@timeout 120 bash -c 'until oc get gateway -n $(BOOKINFO_NS) waypoint -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null | grep -q "True"; do sleep 5; done' || \
	  echo "WARNING: Bookinfo waypoint not programmed after 120s"
	@echo "=== Bookinfo ready ==="

# --- Phase 9: Testing ---
test:
	@echo "=== Running tests ==="
	@echo "--- Test 1: App A via OCP Route ---"
	@OCP_URL=$$(oc get route app-a -n $(NAMESPACE) -o jsonpath='{.spec.host}' 2>/dev/null) && \
	  if [ -n "$$OCP_URL" ]; then \
	    echo "URL: http://$$OCP_URL"; \
	    curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://$$OCP_URL/" || echo "FAILED"; \
	    echo "--- Test 2: App B via waypoint (OCP Route) ---"; \
	    curl -s "http://$$OCP_URL/app-b" && echo "" || echo "FAILED"; \
	    echo "--- Test 3: App C via waypoint (OCP Route) ---"; \
	    curl -s "http://$$OCP_URL/app-c" && echo "" || echo "FAILED"; \
	  else echo "WARNING: OCP Route not found"; fi
	@echo ""
	@echo "--- Test 4: App A via AWS Gateway ---"
	@AWS_HOST=$$(oc get gateway app-gateway-aws -n $(NAMESPACE) -o jsonpath='{.status.addresses[0].value}' 2>/dev/null) && \
	  if [ -n "$$AWS_HOST" ]; then \
	    echo "Host: $$AWS_HOST"; \
	    curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://$$AWS_HOST/" || echo "FAILED"; \
	  else echo "WARNING: AWS Gateway address not found (LB may still be provisioning)"; fi
	@echo ""
	@echo "--- Test 5: Mesh status ---"
	oc get pods -n $(NAMESPACE) -o wide
	@echo ""
	oc get gateway -n $(NAMESPACE)
	@echo ""
	oc get httproute -n $(NAMESPACE)
	@echo ""
	@echo "=== Tests complete ==="

# --- E2E Tests ---
test-e2e:
	@echo "=== Running E2E test suite ==="
	NAMESPACE=$(NAMESPACE) BOOKINFO_NS=$(BOOKINFO_NS) ./tests/e2e.sh

# --- Cleanup ---
clean-bookinfo:
	@echo "=== Cleaning up Bookinfo ==="
	-helm uninstall bookinfo 2>/dev/null
	-oc delete namespace $(BOOKINFO_NS) --ignore-not-found
	@echo "=== Bookinfo cleanup complete ==="

clean: clean-bookinfo
	@echo "=== Cleaning up ==="
	-helm uninstall observability 2>/dev/null
	-helm uninstall security 2>/dev/null
	-helm uninstall gateway-routing 2>/dev/null
	-helm uninstall apps 2>/dev/null
	-helm uninstall control-plane 2>/dev/null
	-helm uninstall operators 2>/dev/null
	-oc delete namespace $(NAMESPACE) --ignore-not-found
	-oc delete namespace $(ISTIO_NS) --ignore-not-found
	-oc delete namespace istio-cni --ignore-not-found
	-oc delete namespace ztunnel --ignore-not-found
	-oc delete namespace $(TEMPO_NS) --ignore-not-found
	-oc delete namespace openshift-operators-redhat --ignore-not-found
	@echo "=== Cleanup complete ==="
