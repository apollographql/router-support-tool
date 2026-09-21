#!/usr/bin/env bash
# Polls a router pod's own :9090/metrics directly (not through its Service) until it
# serves real Prometheus output, or times out. A Deployment's Available condition only
# guarantees its own readinessProbe target responds - the official chart's default
# probe checks health_check (:8088), not the prometheus exporter (:9090), so Available
# can turn true slightly before :9090 is actually serving. Bypassing the Service here
# also means kube-proxy/Endpoints propagation lag can't be a second source of flakiness
# on top of that.
#
# One probe pod is created up front and reused via `kubectl exec` for every retry.
#
# Usage: wait_for_metrics.sh <namespace> [selector] [port]
set -euo pipefail

NAMESPACE=$1
SELECTOR="${2:-app.kubernetes.io/name=router}"
PORT="${3:-9090}"
PROBE_POD="metrics-probe-$$"

cleanup() {
  kubectl delete pod "$PROBE_POD" -n "$NAMESPACE" --ignore-not-found --wait=false > /dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl run "$PROBE_POD" --image=curlimages/curl:8.10.1 -n "$NAMESPACE" --restart=Never --command -- sleep 300
kubectl wait --for=condition=Ready "pod/$PROBE_POD" -n "$NAMESPACE" --timeout=60s

for i in $(seq 1 40); do
  POD_IP=$(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  if [ -n "$POD_IP" ]; then
    CURL_EXIT=0
    BODY=$(kubectl exec "$PROBE_POD" -n "$NAMESPACE" -- curl -s -w '\nHTTP_STATUS:%{http_code}' "http://${POD_IP}:${PORT}/metrics" 2>&1) || CURL_EXIT=$?
    if grep -q "apollo_router_" <<< "$BODY"; then
      echo "metrics ready"
      exit 0
    fi
    echo "[attempt $i] pod_ip=$POD_IP curl_exit=$CURL_EXIT response(first 200 chars)=$(echo "$BODY" | head -c 200)" >&2
  else
    echo "[attempt $i] no Running pod found matching selector '$SELECTOR'" >&2
  fi
  sleep 3
done

echo "router :${PORT}/metrics never served real content within the timeout" >&2
exit 1
