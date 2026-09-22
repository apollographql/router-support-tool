#!/usr/bin/env bash
# Installs router-diagnostics (mode: local) against the router already deployed by
# resource.yaml, runs a collection, and checks the resulting bundle against
# specs/collection/base_spec.md's "What the base spec collects" tables.
#
# Usage: verify_raw_manifest_bundle.sh <namespace> <resource-file> <expected-config-file>
#                                       <chart-path> <plugin-path>
# The last two are paths (not repo-root-relative - see the calling chainsaw-test.yaml)
# to the router-diagnostics chart and Helm plugin, since Chainsaw runs this script with
# the test's own directory as its working directory.
set -euo pipefail

NAMESPACE=$1
RESOURCE_FILE=$2
EXPECTED_CONFIG_FILE=$3
CHART_PATH=$4
PLUGIN_PATH=$5

# Extracted from the same manifest the router was actually deployed from
# so it can't drift from Renovate bumping the pinned version.
EXPECTED_IMAGE=$(grep -m1 'image: ghcr.io/apollographql/router:' "$RESOURCE_FILE" | sed 's/^ *image: *//')

RELEASE_NAME="router-diagnostics"

helm install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --set namespace="$NAMESPACE" \
  --set mode=local

helm plugin list | grep -q router-diagnostics || helm plugin install "$PLUGIN_PATH"

helm router-diagnostics collect "$RELEASE_NAME" -n "$NAMESPACE"

BUNDLE=$(ls -t support-bundle-*.tar.gz | head -1)
DIR="${BUNDLE%.tar.gz}"
tar xzf "$BUNDLE"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Check meta.json: render-time facts (see specs/collection/meta_json.md)
META="$DIR/meta.json"
[ "$(jq -r '.mode' "$META")" = "local" ] || fail "meta.json mode != local"
[ "$(jq -r '.namespace' "$META")" = "$NAMESPACE" ] || fail "meta.json namespace != $NAMESPACE"

# Check router-metrics/result.json (collected via the http collector): make sure we got a real Prometheus scrape
RESULT="$DIR/router-metrics/result.json"
[ "$(jq -r '.response.status' "$RESULT")" = "200" ] || fail "router-metrics: response.status != 200"
jq -r '.response.body' "$RESULT" | grep -q "apollo_router_" || fail "router-metrics: body doesn't contain real router metrics"

# Check clusterResources collector: pod is Running, zero restarts, expected image + resources are in the support bundle
PODS="$DIR/cluster-resources/pods/$NAMESPACE.json"
MATCHED=$(jq --arg k "app.kubernetes.io/name" --arg v router \
  '[.items[] | select(.metadata.labels[$k] == $v)] | length' "$PODS")
[ "$MATCHED" -gt 0 ] || fail "no pods matched label app.kubernetes.io/name=router"
jq -e --arg image "$EXPECTED_IMAGE" '
  [.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "router")] | all(
    .status.phase == "Running"
    and .status.containerStatuses[0].restartCount == 0
    and .spec.containers[0].image == $image
    and .spec.containers[0].resources.requests.cpu == "100m"
    and .spec.containers[0].resources.requests.memory == "128Mi"
    and .spec.containers[0].resources.limits.cpu == "500m"
    and .spec.containers[0].resources.limits.memory == "256Mi"
  )' "$PODS" > /dev/null || fail "clusterResources: pod health/image/resources check failed"

# Check clusterResources collector: node MemoryPressure/DiskPressure
NODES="$DIR/cluster-resources/nodes.json"
for CONDITION in MemoryPressure DiskPressure; do
  jq -e --arg c "$CONDITION" '
    [.items[].status.conditions[] | select(.type == $c) | .status] as $statuses
    | ($statuses | length > 0) and (all($statuses[]; . == "False"))
  ' "$NODES" > /dev/null || fail "clusterResources: node $CONDITION not all False (or missing)"
done

# Check nodeMetrics collector: real kubelet data, including cpu.psi/memory.psi
NODE_METRICS_DIR="$DIR/node-metrics"
[ -d "$NODE_METRICS_DIR" ] || fail "no node-metrics directory in bundle"
SAW_ROUTER_CONTAINER=false
for f in "$NODE_METRICS_DIR"/*.json; do
  [ -e "$f" ] || fail "no *.json files under node-metrics"
  jq -e '.node.memory.availableBytes != null' "$f" > /dev/null \
    || fail "node-metrics: node.memory.availableBytes missing in $f"
  if jq -e '[.pods[]?.containers[]? | select(.name == "router")] | length > 0' "$f" > /dev/null; then
    SAW_ROUTER_CONTAINER=true
    jq -e '
      [.pods[].containers[] | select(.name == "router")] | all(
        .memory.workingSetBytes != null and .memory.rssBytes != null
        and .memory.usageBytes != null and .memory.pageFaults != null
        and .memory.majorPageFaults != null and .memory.psi != null
        and .cpu.usageNanoCores != null and .cpu.usageCoreNanoSeconds != null
        and .cpu.psi != null
      )' "$f" > /dev/null || fail "node-metrics: router container missing an expected field in $f"
  fi
done
[ "$SAW_ROUTER_CONTAINER" = true ] || fail "no container named router found in any node-metrics/*.json"

# Check router-logs
FOUND_TARGET=false
for log in "$DIR"/router-logs/*/router.log; do
  [ -e "$log" ] || continue
  if jq -e 'select(.target == "apollo_router::axum_factory::axum_http_server_factory")' "$log" > /dev/null 2>&1; then
    FOUND_TARGET=true
    break
  fi
done
[ "$FOUND_TARGET" = true ] || fail "no router.log contained the expected startup target"

# APOLLO_KEY must never appear anywhere in the bundle
if grep -rq "APOLLO_KEY" "$DIR"; then
  fail "APOLLO_KEY found in bundle contents - this must never happen"
fi

# Check configMap collector: collected router.yaml matches the real config
CONFIG="$DIR/configmaps/$NAMESPACE/router-config.json"
COLLECTED=$(jq -r '.data["router.yaml"]' "$CONFIG")
EXPECTED=$(cat "$EXPECTED_CONFIG_FILE")
if [ "$COLLECTED" != "$EXPECTED" ]; then
  echo "--- expected ---"
  echo "$EXPECTED"
  echo "--- collected ---"
  echo "$COLLECTED"
  fail "collected router.yaml doesn't match $EXPECTED_CONFIG_FILE"
fi

echo "All checks passed."
