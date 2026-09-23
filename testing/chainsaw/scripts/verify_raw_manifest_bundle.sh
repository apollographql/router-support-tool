#!/usr/bin/env bash
# Installs router-diagnostics (mode: local) against the router already deployed by
# resource.yaml, runs a collection, and checks the resulting bundle against
# specs/collection/base_spec.md's "What the base spec collects" tables.
#
# Usage: verify_raw_manifest_bundle.sh <namespace> <resource-file> <chart-path> <collect-script-path>
# The last two are paths (not repo-root-relative - see the calling chainsaw-test.yaml)
# to the router-diagnostics-chart chart directory and the router-diagnostics-helm-plugin
# directory, since Chainsaw runs this script with the test's own directory as its working
# directory.
set -euo pipefail

NAMESPACE=$1
RESOURCE_FILE=$2
CHART_PATH=$3
COLLECT_SCRIPT=$4

# Extracted from the same manifest the router was actually deployed from
# so it can't drift from Renovate bumping the pinned version.
EXPECTED_IMAGE=$(grep -m1 'image: ghcr.io/apollographql/router:' "$RESOURCE_FILE" | sed 's/^ *image: *//')

RELEASE_NAME="router-diagnostics"

helm install "$RELEASE_NAME" "$CHART_PATH" -n "$NAMESPACE" \
  --set namespace="$NAMESPACE" \
  --set mode=local \
  --set metricsPort=9091

"$COLLECT_SCRIPT" --namespace "$NAMESPACE" "$RELEASE_NAME"

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
grep -q "apollo_router_" <<< "$(jq -r '.response.body' "$RESULT")" || fail "router-metrics: body doesn't contain real router metrics"

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

CONFIG="$DIR/configmaps/$NAMESPACE/router-config.json"

# --- Redaction tests: every sentinel value planted in the fixtures is named SENTINEL_* -
# one blanket check catches any of them leaking unredacted, rather than naming each one.
# Paired with positive-survives checks below, so an empty/absent section can't be
# mistaken for a rule that fired.
if grep -q "SENTINEL" "$CONFIG"; then
  fail "a sentinel value was found unredacted in the collected config"
fi
if grep -q "demo.starstuff.dev" "$CONFIG"; then
  fail "the real subgraph URL domain was found unredacted in the supergraph schema"
fi

jq -e '.data["router.yaml"] | contains("service_name: vpc-lattice-svcs")' "$CONFIG" > /dev/null \
  || fail "AWS SigV4 hardcoded: non-secret sibling field didn't survive"
# default_chain holds no literal credential and must survive untouched.
jq -e '.data["router.yaml"] | contains("default_chain") and contains("region: us-east-1")' "$CONFIG" > /dev/null \
  || fail "AWS SigV4 default_chain didn't survive untouched"
jq -e '.data["router.yaml"] | contains("x-sentinel-static") and contains("x-sentinel-frombody") and contains("x-sentinel-source-header")' "$CONFIG" > /dev/null \
  || fail "header names (block style) didn't survive"
jq -e '.data["router.yaml"] | contains("x-sentinel-flow-static") and contains("x-sentinel-flow-frombody") and contains("x-sentinel-flow-source")' "$CONFIG" > /dev/null \
  || fail "header names (flow style) didn't survive"
jq -e '.data["supergraph.graphql"] | contains("name: \"accounts\"")' "$CONFIG" > /dev/null \
  || fail "subgraph name didn't survive in the supergraph schema"
jq -e '.data["supergraph.graphql"] | contains("@source(") and contains("name: \"api\"")' "$CONFIG" > /dev/null \
  || fail "connector source name didn't survive in the supergraph schema"
jq -e '.data["supergraph.graphql"] | contains("specs.apollo.dev/link")' "$CONFIG" > /dev/null \
  || fail "@link URL didn't survive in the supergraph schema"

# supergraph and subgraph client-auth keys are EC, connector's is a longer RSA key.
TLS_YAML=$(jq -r '.data["router.yaml"]' "$CONFIG")
EC_MASKED=$(echo "$TLS_YAML" | grep -c -- '-----BEGIN EC PRIVATE KEY-----\*\*\*HIDDEN\*\*\*-----END EC PRIVATE KEY-----')
PLAIN_MASKED=$(echo "$TLS_YAML" | grep -c -- '-----BEGIN PRIVATE KEY-----\*\*\*HIDDEN\*\*\*-----END PRIVATE KEY-----')
[ "$EC_MASKED" -eq 2 ] || fail "expected 2 masked EC private keys, got $EC_MASKED"
[ "$PLAIN_MASKED" -eq 1 ] || fail "expected 1 masked RSA/generic private key, got $PLAIN_MASKED"
# 6 certificates ship in this file (supergraph cert + chain, two certificate_authorities
# CAs, two client_authentication chains) - none of them secret, all untouched.
CERT_COUNT=$(echo "$TLS_YAML" | grep -o -- '-----BEGIN CERTIFICATE-----' | wc -l)
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
