#!/usr/bin/env sh
set -eux

sh "$ENV_SETUP_SCRIPT"

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

# Generates the log line the operation bodies' redactor needs to be tested against.
# router.yaml logs raw request/response bodies, but only if an operation actually runs. 
# The sentinel value travels in via a variable and is asserted redacted below.
# tls.supergraph is also set in router.yaml, so this is https with -k for the self-signed cert.
curl -sk -X POST "https://router.${NAMESPACE}.svc.cluster.local:4000/" \
  -H "Content-Type: application/json" \
  -d '{"query":"query FetchSentinelUser($sentinelId: ID!) { user(id: $sentinelId) { id name } }","variables":{"sentinelId":"SENTINEL_OPERATION_BODY_VALUE"}}'

# job.collectNodeMetrics=false because the scenario service account can't be granted
# the cluster-scoped ClusterRole/ClusterRoleBinding this collector needs.
# We decline it up front rather than fail the whole install (Prometheus is preferred).
#
# selector=app=router: our own manifests use "app: router" (raw-manifest/custom tier),
# not the official chart's "app.kubernetes.io/name: router" convention that the chart's
# collectors default to when this is left unset - without it, logs/metrics/configMap all
# silently come back empty because nothing actually matches.
helm install router-diagnostics "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set namespace="$NAMESPACE" \
  --set mode=job \
  --set selector=app=router \
  --set job.image.repository=us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-docker/router-diagnostics \
  --set job.image.tag=edge \
  --set job.image.pullPolicy=IfNotPresent \
  --set job.collectNodeMetrics=false \
  --set job.storage.provider=url \
  --set job.storage.url.endpoint="http://mock-backend.${NAMESPACE}.svc.cluster.local:8080/bundle.tar.gz" \
  --wait --timeout=60s

kubectl wait --for=condition=complete job/router-diagnostics-job -n "$NAMESPACE" --timeout=120s

# Capture the Job's own container output into the scenario's log
echo "--- router-diagnostics-job logs ---"
kubectl logs -n "$NAMESPACE" job/router-diagnostics-job --all-containers --timestamps || true
echo "--- end router-diagnostics-job logs ---"

curl -sf "http://mock-backend.${NAMESPACE}.svc.cluster.local:8080/bundle.tar.gz" -o /tmp/bundle.tar.gz
test -s /tmp/bundle.tar.gz

# Keep the raw bundle alongside $RTF_OUTPUT so it's retrievable later via
# `rtf remote execution-output``.
cp /tmp/bundle.tar.gz "$(dirname "$RTF_OUTPUT")/bundle.tar.gz"

mkdir -p /tmp/extracted
tar xzf /tmp/bundle.tar.gz -C /tmp/extracted
BUNDLE_DIR=$(find /tmp/extracted -maxdepth 1 -type d -name 'support-bundle-*')
test -n "$BUNDLE_DIR"

# --- Root files the engine always writes (see specs/collection/output.md) ---
test -f "$BUNDLE_DIR/version.yaml"
test -f "$BUNDLE_DIR/analysis.json"
test -f "$BUNDLE_DIR/meta.json"

# --- meta.json: check the render-time facts we know ahead of time
grep -q '"mode": *"job"' "$BUNDLE_DIR/meta.json"
grep -q "\"namespace\": *\"$NAMESPACE\"" "$BUNDLE_DIR/meta.json"
grep -q '"sidecar_injection_disabled": *true' "$BUNDLE_DIR/meta.json"

# Every section below should have data to collect. An empty one here is an error.
find "$BUNDLE_DIR/router-logs" -name '*.log' -size +0 | grep -q .               # router container logs

# clusterResources collector: assert the router pod's own image tag was captured correctly
jq -e --arg version "$ROUTER_VERSION" '
  [.items[] | select(.metadata.labels.app == "router") | .spec.containers[0].image]
  | any(. == "ghcr.io/apollographql/router:" + $version)
' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"

# clusterResources collector: pod status and restart counts.
# Every router pod should be Running by this point regardless of condition - env_setup.sh
# always waits for Ready before returning control here.
jq -e '[.items[] | select(.metadata.labels.app == "router") | .status.phase] | all(. == "Running")' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"

case "$CONDITION" in
  router-recently-restarted)
    # Exactly one router pod was restarted in place by env_setup.sh - assert exactly one
    # has a nonzero restart count.
    jq -e '[.items[] | select(.metadata.labels.app == "router") | .status.containerStatuses[0].restartCount | select(. > 0)] | length == 1' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"
    ;;
  *)
    jq -e '[.items[] | select(.metadata.labels.app == "router") | .status.containerStatuses[0].restartCount] | all(. == 0)' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"
    ;;
esac

# clusterResources collector: configured resource requests/limits are captured - set on
# the router container in router-manifest.yaml purely so this has a real value to check.
jq -e '
  [.items[] | select(.metadata.labels.app == "router") | .spec.containers[0].resources]
  | all(.requests.cpu == "100m" and .requests.memory == "128Mi"
        and .limits.cpu == "500m" and .limits.memory == "256Mi")
' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"

# clusterResources collector: node MemoryPressure/DiskPressure - NOT positively testable
# Listing nodes needs the same cluster-scoped "nodes: list" RBAC that
# job.collectNodeMetrics=false already declines above so cluster-resources/nodes.json
# should correctly come back with an empty items array.
grep -qi "forbidden" "$BUNDLE_DIR/cluster-resources/nodes-errors.json"

# configMap collector: assert the collected router.yaml matches the expected config byte
# for byte. $EXPECTED_REDACTED_ROUTER_CONFIG is base-router-config.yaml with the redactors'
# masking already applied.
jq -j '.data["router.yaml"]' "$BUNDLE_DIR/configmaps/$NAMESPACE/router-config.json" > /tmp/collected-router-config.yaml
diff "$EXPECTED_REDACTED_ROUTER_CONFIG" /tmp/collected-router-config.yaml

# job mode emits one http collector per pod: router-metrics-<pod-name>/result.json.
# If no files exist the selector didn't match any pods at render time.
METRICS_FILES=$(find "$BUNDLE_DIR" -path "*/router-metrics-*/result.json" -type f 2>/dev/null)
[ -n "$METRICS_FILES" ] || { echo "router-metrics: no per-pod result files found — selector/label mismatch at render time?" >&2; exit 1; }

case "$CONDITION" in
  all-metrics-misconfigured)
    # Every router has prometheus.enabled=false, so every scrape should fail —
    # no # HELP line in any result.
    UNEXPECTED=false
    while IFS= read -r f; do
      if jq -r '.response.body' "$f" | grep -q '# HELP'; then
        echo "router-metrics: unexpected # HELP in $f" >&2
        UNEXPECTED=true
      fi
    done <<METRICS_EOF
$METRICS_FILES
METRICS_EOF
    [ "$UNEXPECTED" = false ] || exit 1
    ;;
  healthy)
    # At least one pod's scrape should return real metrics text.
    FOUND=false
    while IFS= read -r f; do
      if jq -r '.response.body' "$f" | grep -q '# HELP'; then
        FOUND=true
        break
      fi
    done <<METRICS_EOF
$METRICS_FILES
METRICS_EOF
    [ "$FOUND" = true ] || { echo "router-metrics: no result file contains # HELP" >&2; exit 1; }
    ;;
esac

# --- Router recently restarted: the logs collector's previous-container capture ---
if [ "$CONDITION" = "router-recently-restarted" ]; then
  # troubleshoot.sh always requests the previous container's log when one exists,
  # see specs/collection/base_spec.md, written as <name>-previous.log.
  PREVIOUS_LOG=$(find "$BUNDLE_DIR/router-logs" -name '*-previous.log')
  test -n "$PREVIOUS_LOG"
  test -s "$PREVIOUS_LOG"
  grep -q '"message":"state machine transitioned"' "$PREVIOUS_LOG"
  grep -q '"state":"Startup"' "$PREVIOUS_LOG"

  # The current (post-restart) container's own log must also show a fresh startup.
  CURRENT_LOG="$(dirname "$PREVIOUS_LOG")/router.log"
  test -f "$CURRENT_LOG"
  grep -q '"message":"state machine transitioned"' "$CURRENT_LOG"
  grep -q '"state":"Startup"' "$CURRENT_LOG"
fi

# --- APOLLO_KEY must never be collected ---
if grep -rq "APOLLO_KEY" "$BUNDLE_DIR"; then
  echo "APOLLO_KEY found in bundle contents - this must never happen" >&2
  exit 1
fi

# --- Redaction tests: The sentinel value must be gone and something structurally
# adjacent must survive, so an empty/absent section can't be mistaken for a rule that fired.
CONFIGMAP_JSON=$(find "$BUNDLE_DIR/configmaps" -name 'router-config.json')
test -n "$CONFIGMAP_JSON"

# JWT and auth config redaction tests - JWKS-fetch headers,
# block-style, single-entry flow, and two-entry flow all redacted.
# url/issuers/algorithms are untouched.
if grep -qE "SENTINEL_JWKS_HEADER_VALUE|SENTINEL_JWKS_FLOW_HEADER_SINGLE|SENTINEL_JWKS_FLOW_MULTI_FIRST|SENTINEL_JWKS_FLOW_MULTI_SECOND" "$CONFIGMAP_JSON"; then
  echo "JWKS-fetch header sentinel found unredacted in bundle" >&2
  exit 1
fi
grep -q "x-vault-token" "$CONFIGMAP_JSON"      # header name untouched
grep -q "issuer.example.com" "$CONFIGMAP_JSON" # issuers/algorithms/url are not secret
grep -q "RS256" "$CONFIGMAP_JSON"
grep -q "jwks-not-found" "$CONFIGMAP_JSON"
grep -q "x-flow-multi-a" "$CONFIGMAP_JSON"     # both flow-list header names are untouched
grep -q "x-flow-multi-b" "$CONFIGMAP_JSON"

# The pathless-URL and quoted-username/password sentinels here live in a commented-out
# fixture in router.yaml. Redaction is plain text matching so a
# commented-out line is still real input to it.
if grep -qE "SENTINEL_REDIS_URL_PASSWORD|SENTINEL_REDIS_PATHLESS_PASSWORD|SENTINEL_REDIS_USERNAME|SENTINEL_REDIS_PASSWORD" "$CONFIGMAP_JSON"; then
  echo "Redis credential sentinel found unredacted in bundle" >&2
  exit 1
fi
grep -q "required_to_start" "$CONFIGMAP_JSON" # non-secret redis field survives
if grep -qE "SENTINEL_AWS_ACCESS_KEY_ID|SENTINEL_AWS_SECRET_ACCESS_KEY" "$CONFIGMAP_JSON"; then
  echo "AWS SigV4 hardcoded credential sentinel found unredacted in bundle" >&2
  exit 1
fi
grep -q "service_name: vpc-lattice-svcs" "$CONFIGMAP_JSON" # non-secret sibling field survives

# Header values redaction tests
if grep -qE "SENTINEL_HEADER_INSERT_VALUE|SENTINEL_HEADER_INSERT_DEFAULT|SENTINEL_HEADER_PROPAGATE_DEFAULT" "$CONFIGMAP_JSON"; then
  echo "Header plugin literal value sentinel found unredacted in bundle" >&2
  exit 1
fi
grep -q "x-sentinel-static" "$CONFIGMAP_JSON"       # header names survive
grep -q "x-sentinel-frombody" "$CONFIGMAP_JSON"
grep -q "x-sentinel-source-header" "$CONFIGMAP_JSON"

# Subgraph urls redaction tests
if grep -q "SENTINEL_SUBGRAPH_URL_PASSWORD" "$CONFIGMAP_JSON"; then
  echo "override_subgraph_url sentinel found unredacted in bundle" >&2
  exit 1
fi

# Subgraph urls redaction tests - schema URLs, subgraph names untouched
if grep -q "0.0.0.0:4200" "$CONFIGMAP_JSON"; then
  echo "supergraph.graphql subgraph URL found unredacted in bundle" >&2
  exit 1
fi
grep -qF 'name: \"accounts\"' "$CONFIGMAP_JSON"
# @link pins the federation spec version, not a customer host - stays unredacted
grep -qF 'specs.apollo.dev/link' "$CONFIGMAP_JSON"

# TLS private keys - all three key locations masked,
# certificates/chains untouched.
KEY_COUNT=$(grep -o -- '-----BEGIN EC PRIVATE KEY-----[^-]*-----END EC PRIVATE KEY-----' "$CONFIGMAP_JSON" | grep -c '\*\*\*HIDDEN\*\*\*')
test "$KEY_COUNT" -eq 3
grep -q -- "-----BEGIN CERTIFICATE-----" "$CONFIGMAP_JSON"

# Operation bodies - the request/response bodies logged for the sentinel operation
# above must be masked, with everything else in the log line intact.
ROUTER_LOG=$(find "$BUNDLE_DIR/router-logs" -name '*.log')
test -n "$ROUTER_LOG"
if grep -q "SENTINEL_OPERATION_BODY_VALUE" $ROUTER_LOG; then
  echo "Operation body sentinel found unredacted in router logs" >&2
  exit 1
fi
grep -q '"kind":"supergraph.request"' $ROUTER_LOG
grep -q '"kind":"supergraph.response"' $ROUTER_LOG
grep -q '"http.request.body":"\*\*\*HIDDEN\*\*\*"' $ROUTER_LOG
grep -q '"http.response.body":"\*\*\*HIDDEN\*\*\*"' $ROUTER_LOG

# Surrounding fields stay - the redaction must be scoped to the body value only.
grep -q '"level":"INFO"' $ROUTER_LOG
grep -q '"trace_id":"' $ROUTER_LOG
grep -q '"target":"apollo_router::plugins::telemetry::config_new::events"' $ROUTER_LOG

# The mask must not have run on past the closing quote it belongs to: the whole
# quoted value must be exactly ***HIDDEN***.
# (Checked this way, not by adjacency to a specific next key, since the router's
# field order for headers vs. body isn't guaranteed across versions.)
grep -ohE '"http\.request\.body":"[^"]*"' $ROUTER_LOG | grep -qxF '"http.request.body":"***HIDDEN***"'
grep -ohE '"http\.response\.body":"[^"]*"' $ROUTER_LOG | grep -qxF '"http.response.body":"***HIDDEN***"'

tar tzf /tmp/bundle.tar.gz > /tmp/bundle-contents.txt
{
  echo "Bundle retrieved and verified. Contents:"
  cat /tmp/bundle-contents.txt
} | tee "$RTF_OUTPUT"
