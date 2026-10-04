#!/usr/bin/env bash
# Installs router-diagnostics (mode: local) against the router already deployed by the
# official apollographql/router Helm chart, runs a collection, and checks the resulting
# bundle against specs/collection/base_spec.md's "What the base spec collects" tables.
#
# Usage: verify_official_chart_bundle.sh <namespace> <chart-path> <collect-script-path>
#                                         <expected-graph-ref>
# chart-path/collect-script-path are not repo-root-relative - see the calling
# chainsaw-test.yaml, which runs this with the test's own directory as its working directory.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/assert_host_collector_diagnostics_redacted.sh"

NAMESPACE=$1
CHART_PATH=$2
COLLECT_SCRIPT=$3
EXPECTED_GRAPH_REF=$4

RELEASE_NAME="router-diagnostics"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

helm install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --set namespace="$NAMESPACE" \
  --set mode=local

"$COLLECT_SCRIPT" --namespace "$NAMESPACE"

# --- collect.sh caches the pinned support-bundle binary on first use ---
# This CI runner starts with no pre-existing cache, so the call above just exercised the
# real download-from-GitHub path.
PINNED_VERSION=$(grep -m1 '^SUPPORT_BUNDLE_VERSION=' "$COLLECT_SCRIPT" | sed -E 's/^SUPPORT_BUNDLE_VERSION="(.*)"$/\1/')
[ -n "$PINNED_VERSION" ] || fail "couldn't extract SUPPORT_BUNDLE_VERSION from $COLLECT_SCRIPT"
CACHED_BIN="$HOME/.router-diagnostics/bin/support-bundle-v${PINNED_VERSION}"
[ -x "$CACHED_BIN" ] || fail "collect.sh didn't cache the pinned binary at $CACHED_BIN"

BUNDLE=$(ls -t support-bundle-*.tar.gz | head -1)
DIR="${BUNDLE%.tar.gz}"
tar xzf "$BUNDLE"

# --- meta.json: render-time facts (specs/collection/meta_json.md) ---
META="$DIR/meta.json"
[ "$(jq -r '.mode' "$META")" = "local" ] || fail "meta.json mode != local"
[ "$(jq -r '.namespace' "$META")" = "$NAMESPACE" ] || fail "meta.json namespace != $NAMESPACE"
EXPECTED_VERSION=$(grep -m1 '^version:' "$CHART_PATH/Chart.yaml" | awk '{print $2}')
[ "$(jq -r '.version' "$META")" = "$EXPECTED_VERSION" ] || fail "meta.json version != $CHART_PATH/Chart.yaml's version ($EXPECTED_VERSION)"

# --- router-metrics (run host collector): one .txt per pod via outputDir ---
EXPECTED_METRICS_DIR="$DIR/host-collectors/run-host/router-metrics/pods"
[ -d "$EXPECTED_METRICS_DIR" ] || fail "router-metrics: expected directory $EXPECTED_METRICS_DIR not found - did the troubleshoot.sh version change where a host run collector's outputDir lands?"
FOUND=false
while IFS= read -r f; do
  grep -q "apollo_router_" "$f" && FOUND=true && break
done < <(find "$EXPECTED_METRICS_DIR" -maxdepth 1 -name "*.txt" -type f 2>/dev/null)
[ "$FOUND" = true ] || fail "router-metrics: no per-pod metrics file contains apollo_router_ metrics"

# --- host-collector diagnostic sidecar: present and fully redacted (see
# specs/collection/data_sanitization/host_collector_diagnostics.md) ---
assert_host_collector_diagnostics_redacted "$DIR"

# --- clusterResources: pod is Running, zero restarts, expected resources ---
# No image check here (unlike raw-manifest) - the official chart pins its own image tag,
# not one of our test fixtures.
PODS="$DIR/cluster-resources/pods/$NAMESPACE.json"
MATCHED=$(jq --arg k "app.kubernetes.io/name" --arg v router \
  '[.items[] | select(.metadata.labels[$k] == $v)] | length' "$PODS")
[ "$MATCHED" -gt 0 ] || fail "no pods matched label app.kubernetes.io/name=router"
jq -e '
  [.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "router")] | all(
    .status.phase == "Running"
    and .status.containerStatuses[0].restartCount == 0
    and .spec.containers[0].resources.requests.cpu == "100m"
    and .spec.containers[0].resources.requests.memory == "128Mi"
    and .spec.containers[0].resources.limits.cpu == "500m"
    and .spec.containers[0].resources.limits.memory == "256Mi"
  )' "$PODS" > /dev/null || fail "clusterResources: pod health/resources check failed"

# --- clusterResources: APOLLO_GRAPH_REF/APOLLO_ROUTER_OFFICIAL_HELM_CHART env vars ---
# Only the official chart is guaranteed to set these (specs/deployment/v1/v1.md).
jq -e --arg ref "$EXPECTED_GRAPH_REF" '
  [.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "router")] | all(
    (.spec.containers[0].env // [] | any(.name == "APOLLO_ROUTER_OFFICIAL_HELM_CHART" and .value == "true"))
    and (.spec.containers[0].env // [] | any(.name == "APOLLO_GRAPH_REF" and .value == $ref))
  )' "$PODS" > /dev/null || fail "APOLLO_GRAPH_REF/APOLLO_ROUTER_OFFICIAL_HELM_CHART env vars missing or wrong"

# --- clusterResources: node MemoryPressure/DiskPressure both False ---
NODES="$DIR/cluster-resources/nodes.json"
for CONDITION in MemoryPressure DiskPressure; do
  jq -e --arg c "$CONDITION" '
    [.items[].status.conditions[] | select(.type == $c) | .status] as $statuses
    | ($statuses | length > 0) and (all($statuses[]; . == "False"))
  ' "$NODES" > /dev/null || fail "clusterResources: node $CONDITION not all False (or missing)"
done

# --- nodeMetrics: real kubelet data, including cpu.psi/memory.psi (KubeletPSI gate) ---
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

# --- router-logs: startup log line present ---
FOUND_TARGET=false
for log in "$DIR"/router-logs/*/router.log; do
  [ -e "$log" ] || continue
  if jq -e 'select(.target == "apollo_router::axum_factory::axum_http_server_factory")' "$log" > /dev/null 2>&1; then
    FOUND_TARGET=true
    break
  fi
done
[ "$FOUND_TARGET" = true ] || fail "no router.log contained the expected startup target"

# --- APOLLO_KEY must never appear anywhere in the bundle ---
if grep -rq "APOLLO_KEY" "$DIR"; then
  fail "APOLLO_KEY found in bundle contents - this must never happen"
fi

# --- configMap collector: expected prometheus fields survive the chart's own templating ---
# Not an exact-diff (unlike raw-manifest) - templates/configmap.yaml's mustMergeOverwrite
# injects telemetry.exporters.metrics.common.resource.service.name on top of whatever we
# pass in values.yaml, so only specific fields are checked here.
CONFIG="$DIR/configmaps/$NAMESPACE/router.json"
COLLECTED_YAML=$(jq -r '.data["configuration.yaml"]' "$CONFIG")
jq -e '.data["configuration.yaml"] | contains("enabled: true")' "$CONFIG" > /dev/null \
  || fail "collected config: telemetry.exporters.metrics.prometheus.enabled != true"
jq -e '.data["configuration.yaml"] | contains("listen: 0.0.0.0:9090")' "$CONFIG" > /dev/null \
  || fail "collected config: telemetry.exporters.metrics.prometheus.listen != 0.0.0.0:9090"
jq -e '.data["configuration.yaml"] | contains("path: /metrics")' "$CONFIG" > /dev/null \
  || fail "collected config: telemetry.exporters.metrics.prometheus.path != /metrics"

# --- <release>-supergraph ConfigMap (templates/supergraph-cm.yaml), via clusterResources -
# the chart's own supergraph ConfigMap isn't collected by our configMap collector, which
# only targets the rendered router config.
SCHEMA_CONFIG="$DIR/cluster-resources/configmaps/$NAMESPACE.json"

# --- Redaction tests: every sentinel value planted in the fixtures is named SENTINEL_* -
# one blanket check catches any of them leaking unredacted, rather than naming each one.
# Paired with positive-survives checks below, so an empty/absent section can't be
# mistaken for a rule that fired. The router's config here lives under
# "configuration.yaml" (router.json).
#
# This tier is what actually exercises the block-style header redactors' order
# independence: the official chart's own YAML marshaling re-serializes maps
# alphabetically (unlike raw-manifest's hand-authored router.yaml, which happens to
# already write name:/named: before value:/default:), so insert.default and
# propagate.default only get proven order-independent here.
if grep -q "SENTINEL" "$CONFIG"; then
  fail "a sentinel value was found unredacted in the collected config"
fi
if grep -q "demo.starstuff.dev" "$SCHEMA_CONFIG"; then
  fail "the real subgraph URL domain was found unredacted in the supergraph schema"
fi
if grep -q "SENTINEL" <<< "$(jq -r '[.items[] | select(.metadata.name == "router-supergraph")][0].data["supergraph-schema.graphql"]' "$SCHEMA_CONFIG")"; then
  fail "a sentinel value was found unredacted in the supergraph schema"
fi

jq -e '.data["configuration.yaml"] | contains("service_name: vpc-lattice-svcs")' "$CONFIG" > /dev/null \
  || fail "AWS SigV4 hardcoded: non-secret sibling field didn't survive"
jq -e '.data["configuration.yaml"] | contains("default_chain") and contains("region: us-east-1")' "$CONFIG" > /dev/null \
  || fail "AWS SigV4 default_chain didn't survive untouched"
jq -e '.data["configuration.yaml"] | contains("x-sentinel-static") and contains("x-sentinel-frombody") and contains("x-sentinel-source-header")' "$CONFIG" > /dev/null \
  || fail "header names didn't survive"
jq -e '.data["configuration.yaml"] | contains("x-sentinel-flow-static") and contains("x-sentinel-flow-frombody") and contains("x-sentinel-flow-source")' "$CONFIG" > /dev/null \
  || fail "header names (originally flow-style) didn't survive"
jq -e '[.items[] | select(.metadata.name == "router-supergraph")][0].data["supergraph-schema.graphql"] | contains("name: \"accounts\"")' "$SCHEMA_CONFIG" > /dev/null \
  || fail "subgraph name didn't survive in the supergraph schema"
jq -e '[.items[] | select(.metadata.name == "router-supergraph")][0].data["supergraph-schema.graphql"] | contains("@source(") and contains("name: \"api\"")' "$SCHEMA_CONFIG" > /dev/null \
  || fail "connector source name didn't survive in the supergraph schema"
jq -e '[.items[] | select(.metadata.name == "router-supergraph")][0].data["supergraph-schema.graphql"] | contains("specs.apollo.dev/link")' "$SCHEMA_CONFIG" > /dev/null \
  || fail "@link URL didn't survive in the supergraph schema"

# supergraph and subgraph client-auth keys are EC, connector's is a longer RSA key.
EC_MASKED=$(echo "$COLLECTED_YAML" | grep -c -- '-----BEGIN EC PRIVATE KEY-----\*\*\*HIDDEN\*\*\*-----END EC PRIVATE KEY-----')
PLAIN_MASKED=$(echo "$COLLECTED_YAML" | grep -c -- '-----BEGIN PRIVATE KEY-----\*\*\*HIDDEN\*\*\*-----END PRIVATE KEY-----')
[ "$EC_MASKED" -eq 2 ] || fail "expected 2 masked EC private keys, got $EC_MASKED"
[ "$PLAIN_MASKED" -eq 1 ] || fail "expected 1 masked RSA/generic private key, got $PLAIN_MASKED"
# 6 certificates ship in this file (supergraph cert + chain, two certificate_authorities
# CAs, two client_authentication chains) - none of them secret, all untouched.
CERT_COUNT=$(echo "$COLLECTED_YAML" | grep -o -- '-----BEGIN CERTIFICATE-----' | wc -l)
[ "$CERT_COUNT" -eq 6 ] || fail "expected 6 certificates to survive untouched, got $CERT_COUNT"

# Operation body logging - the sentinel operation sent earlier must be masked, with
# everything else in the log line intact. A mis-scoped mask breaks the line's JSON, not
# just the redaction: jq parses strictly, so it fails on that malformed line - giving
# the JSON-validity check operation_bodies.md requires for free, as a side effect.
for log in "$DIR"/router-logs/*/router.log; do
  [ -e "$log" ] || continue
  if grep -q "SENTINEL" "$log"; then
    fail "a sentinel value was found unredacted in $log"
  fi
  jq -e 'select(.kind == "supergraph.request") | .["http.request.body"] == "***HIDDEN***"' "$log" > /dev/null 2>&1 \
    || fail "supergraph.request log line's http.request.body wasn't masked in $log"
  jq -e 'select(.kind == "supergraph.response") | .["http.response.body"] == "***HIDDEN***"' "$log" > /dev/null 2>&1 \
    || fail "supergraph.response log line's http.response.body wasn't masked in $log"
  jq -e 'select(.kind == "supergraph.request") | .level == "INFO" and (.trace_id | length > 0) and (.target | length > 0)' "$log" > /dev/null 2>&1 \
    || fail "surrounding log fields (level/trace_id/target) didn't survive alongside the mask in $log"
done

echo "All checks passed."
