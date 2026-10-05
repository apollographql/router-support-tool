#!/usr/bin/env bash
#
# Usage: verify_metrics_no_servicemonitor.sh <namespace> <chart-path> <collect-script-path>
# The last two are paths relative to chainsaw's own working directory for this test (not
# repo-root-relative) - see the calling chainsaw-test.yaml.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/assert_host_collector_diagnostics_redacted.sh"

NAMESPACE=$1
CHART_PATH=$2
COLLECT_SCRIPT=$3

RELEASE_NAME="router-diagnostics"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

helm install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --set namespace="$NAMESPACE" \
  --set mode=local

"$COLLECT_SCRIPT" --namespace "$NAMESPACE"

BUNDLE=$(ls -t support-bundle-*.tar.gz | head -1)
DIR="${BUNDLE%.tar.gz}"
tar xzf "$BUNDLE"

# Re-confirm the precondition against the bundle itself, not just the live cluster at
# collection time - the collected Service object is what a reader would actually check.
SERVICE_JSON="$DIR/cluster-resources/services/$NAMESPACE.json"
[ -f "$SERVICE_JSON" ] || fail "no collected Service json at $SERVICE_JSON"
jq -e --arg name router '
  [.items[] | select(.metadata.name == $name) | .spec.ports[]?.name] | all(. != "metrics")
' "$SERVICE_JSON" > /dev/null \
  || fail "collected Service 'router' has a metrics port - the precondition this test exists to check didn't hold"

# Check we get Prometheus output, not an empty section or "prometheus may not be enabled".
EXPECTED_METRICS_DIR="$DIR/host-collectors/run-host/router-metrics/pods"
[ -d "$EXPECTED_METRICS_DIR" ] || fail "router-metrics: expected directory $EXPECTED_METRICS_DIR not found - did the troubleshoot.sh version change where a host run collector's outputDir lands?"
FOUND=false
while IFS= read -r f; do
  grep -q "apollo_router_" "$f" && FOUND=true && break
done < <(find "$EXPECTED_METRICS_DIR" -maxdepth 1 -name "*.txt" -type f 2>/dev/null)
[ "$FOUND" = true ] || fail "router-metrics: no per-pod metrics file contains apollo_router_ metrics, despite serviceMonitor.enabled=false and no Service patch - collection may still depend on the Service"

# Check for specs/collection/data_sanitization/host_collector_diagnostics.md:
assert_host_collector_diagnostics_redacted "$DIR"

echo "All checks passed: metrics collected with no Service metrics port and serviceMonitor.enabled=false; the host-collector diagnostic sidecar is present and fully redacted."
