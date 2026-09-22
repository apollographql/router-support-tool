#!/usr/bin/env bash
# Polls a router pod's own :9090/metrics directly (not through its Service) until it
# serves real Prometheus output, or times out. A Deployment's Available condition only
# guarantees its own readinessProbe target responds - the official chart's default
# probe checks health_check (:8088), not the prometheus exporter (:9090), so Available
# can turn true slightly before :9090 is actually serving. Bypassing the Service here
# also means kube-proxy/Endpoints propagation lag can't be a second source of flakiness
# on top of that.
#
# Usage: wait_for_metrics.sh <namespace>
set -euo pipefail

NAMESPACE=$1
SELECTOR="app.kubernetes.io/name=router"

for _ in $(seq 1 20); do
  POD_IP=$(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  if [ -n "$POD_IP" ]; then
    BODY=$(kubectl run "metrics-probe-$(date +%s%N)" --rm -i --restart=Never --quiet \
      --pod-running-timeout=10s \
      --image=curlimages/curl:8.10.1 -n "$NAMESPACE" -- \
      curl -s "http://${POD_IP}:9090/metrics" 2>/dev/null) || true
    if echo "$BODY" | grep -q "apollo_router_"; then
      echo "metrics ready"
      exit 0
    fi
  fi
  sleep 3
done

echo "router :9090/metrics never served real content within the timeout" >&2
exit 1
