#!/usr/bin/env sh
set -eux

sh "$ENV_SETUP_SCRIPT"

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

# Decoupled from the router's own boot config and applied explicitly here
kubectl apply -n "$NAMESPACE" -f "$ROUTER_CONFIG_CONFIGMAP"

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
# come back empty because nothing actually matches.
#
# selector-mismatch leaves it unset on purpose: the default selector then misses this
# environment's pods the same way it misses an official-chart install whose
# app.kubernetes.io/name label was changed by router.nameOverride.
SELECTOR_FLAG="--set selector=app=router"
if [ "$CONDITION" = "selector-mismatch" ]; then
  SELECTOR_FLAG=""
fi
helm install router-diagnostics "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set namespace="$NAMESPACE" \
  --set mode=job \
  $SELECTOR_FLAG \
  --set job.image.repository=us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-docker/router-diagnostics \
  --set job.image.tag="$JOB_IMAGE_TAG" \
  --set job.image.pullPolicy=IfNotPresent \
  --set job.collectNodeMetrics=false \
  --set job.storage.provider=url \
  --set job.storage.url.endpoint="http://mock-backend.${NAMESPACE}.svc.cluster.local:8080/bundle.tar.gz" \
  --wait --timeout=60s

kubectl wait --for=condition=complete job/router-diagnostics-job-1 -n "$NAMESPACE" --timeout=120s

# Capture the Job's own container output into the scenario's log
echo "--- router-diagnostics-job logs ---"
kubectl logs -n "$NAMESPACE" job/router-diagnostics-job-1 --all-containers --timestamps || true
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
EXPECTED_VERSION=$(grep -m1 '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}')
grep -q "\"version\": *\"$EXPECTED_VERSION\"" "$BUNDLE_DIR/meta.json"

# --- router-metrics: the run collector's own output names every missing pod's reason
# (specs/collection/base_spec.md -> Per-pod metrics collection). Scraped pods land in
# pods/<pod-name>.txt (specs/collection/output.md -> router-metrics layout).
METRICS_OUTPUT="$BUNDLE_DIR/host-collectors/run-host/router-metrics.txt"
METRICS_DIR="$BUNDLE_DIR/host-collectors/run-host/router-metrics/pods"
test -f "$METRICS_OUTPUT"
if find "$BUNDLE_DIR" -maxdepth 1 -name 'router-metrics-*' | grep -q .; then
  echo "router-metrics: found a top-level router-metrics-<pod> directory from the old http collectors" >&2
  exit 1
fi

# --- Checks that read only the namespace-wide clusterResources pods JSON and the bundle
# as a whole, never the router-logs or configMap collectors. They run for every condition,
# including selector-mismatch, where those two collectors are empty by design.

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

# --- APOLLO_KEY literal-env-value redaction (specs/collection/data_sanitization/secret_shaped_env_vars.md) ---
PODS_JSON="$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"
if ! grep -q '"name": "APOLLO_KEY"' "$PODS_JSON"; then
  echo "APOLLO_KEY env var name not found in $PODS_JSON - positive control failed, the redaction check below would be meaningless" >&2
  exit 1
fi
if ! grep -q '"value": "\*\*\*HIDDEN\*\*\*"' "$PODS_JSON"; then
  echo "APOLLO_KEY env var in $PODS_JSON was not masked" >&2
  exit 1
fi
if grep -rq "SENTINELAPOLLOKEYTESTING123" "$BUNDLE_DIR"; then
  echo "APOLLO_KEY literal value found unredacted in bundle contents - this must never happen" >&2
  exit 1
fi

if [ "$CONDITION" = "selector-mismatch" ]; then
  grep -qxF "metrics not collected: no pods matched selector app.kubernetes.io/name=router in namespace $NAMESPACE" "$METRICS_OUTPUT"
  if [ -n "$(ls "$METRICS_DIR" 2>/dev/null)" ]; then
    echo "router-metrics: per-pod files found although no pod matched the selector" >&2
    exit 1
  fi
  # router-logs and configMap share the same selector, so they're empty here too and the
  # checks below that read them don't apply.
  tar tzf /tmp/bundle.tar.gz > /tmp/bundle-contents.txt
  {
    echo "Bundle retrieved and verified (selector-mismatch). Contents:"
    cat /tmp/bundle-contents.txt
  } | tee "$RTF_OUTPUT"
  exit 0
fi

# Every router pod either has a metrics file or a line naming it.
for pod in $(jq -r '.items[] | select(.metadata.labels.app == "router") | .metadata.name' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"); do
  if [ -f "$METRICS_DIR/$pod.txt" ]; then
    grep -q '# HELP' "$METRICS_DIR/$pod.txt" || { echo "router-metrics: $pod.txt has no # HELP line" >&2; exit 1; }
  else
    grep -qxF "metrics not collected for pod $pod: no response on port 9090" "$METRICS_OUTPUT" || {
      echo "router-metrics: no file and no attribution line for pod $pod" >&2
      echo "--- router-metrics.txt ---" >&2
      cat "$METRICS_OUTPUT" >&2
      echo "--- router-metrics-stderr.txt ---" >&2
      cat "${METRICS_OUTPUT%.txt}-stderr.txt" >&2 || true
      echo "--- end ---" >&2
      exit 1
    }
  fi
done

MISSING_PODS=$(grep -c '^metrics not collected for pod ' "$METRICS_OUTPUT" || true)
case "$CONDITION" in
  all-metrics-misconfigured)
    # Every router has prometheus.enabled=false, so no pod is scraped and the output
    # names the exporter as the likely cause.
    if [ -n "$(ls "$METRICS_DIR" 2>/dev/null)" ]; then
      echo "router-metrics: unexpected per-pod files with every exporter disabled" >&2
      exit 1
    fi
    grep -qxF "metrics not collected: no pod responded on port 9090 — prometheus may not be enabled" "$METRICS_OUTPUT"
    ;;
  some-metrics-misconfigured)
    # env_setup.sh disabled the exporter on exactly one router.
    [ "$MISSING_PODS" -eq 1 ] || { echo "router-metrics: expected exactly one non-responding pod, got $MISSING_PODS" >&2; exit 1; }
    ;;
  *)
    [ "$MISSING_PODS" -eq 0 ] || { echo "router-metrics: $MISSING_PODS pod(s) didn't respond" >&2; cat "$METRICS_OUTPUT" >&2; exit 1; }
    ;;
esac

# Every section below should have data to collect. An empty one here is an error.
find "$BUNDLE_DIR/router-logs" -name '*.log' -size +0 | grep -q .               # router container logs

# configMap collector: assert the collected router.yaml matches the expected config byte
# for byte, up through (not including) override_subgraph_url. $EXPECTED_REDACTED_ROUTER_CONFIG
# is the fixture with the redactors' masking already applied, and deliberately ends right
# before that section.
jq -j '.data["router.yaml"]' "$BUNDLE_DIR/configmaps/$NAMESPACE/router-config.json" > /tmp/collected-router-config.yaml
# Command substitution strips the trailing blank line left behind by cutting right
# before override_subgraph_url, so this matches $EXPECTED_REDACTED_ROUTER_CONFIG's own
# clean ending exactly.
TRUNCATED_COLLECTED_CONFIG=$(sed '/^override_subgraph_url:/,$d' /tmp/collected-router-config.yaml)
printf '%s\n' "$TRUNCATED_COLLECTED_CONFIG" > /tmp/collected-router-config-truncated.yaml
diff "$EXPECTED_REDACTED_ROUTER_CONFIG" /tmp/collected-router-config-truncated.yaml

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

# --- Redaction tests: The sentinel value must be gone and something structurally
# adjacent must survive, so an empty/absent section can't be mistaken for a rule that fired.
#
# base-router-config.yaml is a subset of redaction-testing-router-config.yaml's coverage,
# so everything below runs for every variant.
CONFIGMAP_JSON=$(find "$BUNDLE_DIR/configmaps" -name 'router-config.json')
test -n "$CONFIGMAP_JSON"

# JWT and auth config redaction tests - JWKS-fetch header, block-style entry.
# url/issuers/algorithms are untouched.
#
# In the full config, this and the aws_sig_v4 block below sit right after
# override_subgraph_url, so these checks also cover the known over-redaction
# risk there: a key name may be lost, never real content.
if grep -qE "SENTINEL_JWKS_HEADER_VALUE" "$CONFIGMAP_JSON"; then
  echo "JWKS-fetch header sentinel found unredacted in bundle" >&2
  exit 1
fi
grep -q "x-vault-token" "$CONFIGMAP_JSON"      # header name untouched
grep -q "issuer.example.com" "$CONFIGMAP_JSON" # issuers/algorithms/url are not secret

if grep -qE "SENTINEL_REDIS_USERNAME|SENTINEL_REDIS_PASSWORD" "$CONFIGMAP_JSON"; then
  echo "Redis credential sentinel found unredacted in bundle" >&2
  exit 1
fi
grep -q "required_to_start" "$CONFIGMAP_JSON" # non-secret redis field survives

if grep -qE "SENTINEL_AWS_ACCESS_KEY_ID|SENTINEL_AWS_SECRET_ACCESS_KEY" "$CONFIGMAP_JSON"; then
  echo "AWS SigV4 hardcoded credential sentinel found unredacted in bundle" >&2
  exit 1
fi
grep -q "service_name: vpc-lattice-svcs" "$CONFIGMAP_JSON" # non-secret sibling field survives

# Subgraph urls redaction tests. Two entries, checked by sentinel absence rather than
# an exact diff (see the truncated-diff comment above) - accounts (bare, quoted) is
# deterministically masked by our own redactor; inventory (credentialed, unquoted) is
# left to a troubleshoot.sh built-in, which still must not leak the credential or host.
if grep -q "accounts.internal.svc.cluster.local" "$CONFIGMAP_JSON"; then
  echo "override_subgraph_url bare hostname (accounts) found unredacted in bundle" >&2
  exit 1
fi
if grep -q "SENTINEL_SUBGRAPH_URL_PASSWORD" "$CONFIGMAP_JSON"; then
  echo "override_subgraph_url credential (inventory) found unredacted in bundle" >&2
  exit 1
fi
if grep -q "inventory.internal.svc.cluster.local" "$CONFIGMAP_JSON"; then
  echo "override_subgraph_url hostname (inventory) found unredacted in bundle" >&2
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

# TLS private keys - every private key in the fixture is masked, certificates/chains untouched.
# The expected count is read from the variant's own expected-redacted config rather than
# hardcoded, since variants carry different numbers of keys: three (supergraph, subgraph,
# connector) everywhere, plus the OTLP gRPC client key in the Router 3 fixture. The positive
# control comes first: an expected fixture with no masked keys would make the check vacuous.
EXPECTED_KEY_COUNT=$(grep -c -- 'PRIVATE KEY-----\*\*\*HIDDEN\*\*\*-----END' "$EXPECTED_REDACTED_ROUTER_CONFIG" || true)
test "$EXPECTED_KEY_COUNT" -ge 3
KEY_COUNT=$(grep -o -- '-----BEGIN EC PRIVATE KEY-----[^-]*-----END EC PRIVATE KEY-----' "$CONFIGMAP_JSON" | grep -c '\*\*\*HIDDEN\*\*\*')
if [ "$KEY_COUNT" -ne "$EXPECTED_KEY_COUNT" ]; then
  echo "expected $EXPECTED_KEY_COUNT masked private keys in the collected router.yaml, found $KEY_COUNT" >&2
  exit 1
fi
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

if [ "$REDACTION" = "full" ]; then
  # Extra JWKS shapes (single-entry and two-entry flow-style) that only
  # redaction-testing-router-config.yaml carries.
  if grep -qE "SENTINEL_JWKS_FLOW_HEADER_SINGLE|SENTINEL_JWKS_FLOW_MULTI_FIRST|SENTINEL_JWKS_FLOW_MULTI_SECOND" "$CONFIGMAP_JSON"; then
    echo "JWKS-fetch header sentinel found unredacted in bundle" >&2
    exit 1
  fi
  grep -q "RS256" "$CONFIGMAP_JSON"
  grep -q "jwks-not-found" "$CONFIGMAP_JSON"
  grep -q "x-flow-multi-a" "$CONFIGMAP_JSON"     # both flow-list header names are untouched
  grep -q "x-flow-multi-b" "$CONFIGMAP_JSON"

  # Extra Redis shapes (embedded-URL, pathless, quoted) that live in a commented-out
  # fixture only redaction-testing-router-config.yaml carries. Redaction is plain text
  # matching so a commented-out line is still real input to it.
  if grep -qE "SENTINEL_REDIS_URL_PASSWORD|SENTINEL_REDIS_PATHLESS_PASSWORD" "$CONFIGMAP_JSON"; then
    echo "Redis credential sentinel found unredacted in bundle" >&2
    exit 1
  fi

  # Response cache and OTLP gRPC key sentinels - only the Router 3 fixture
  # (redaction-testing-router-config-v3.yaml) carries these; on other versions they are
  # absent, so the check passes trivially.
  if grep -qE "SENTINEL_RESPONSE_CACHE_URL_PASSWORD|SENTINEL_RESPONSE_CACHE_REDIS_USERNAME|SENTINEL_RESPONSE_CACHE_REDIS_PASSWORD|SENTINEL_INVALIDATION_SHARED_KEY" "$CONFIGMAP_JSON"; then
    echo "Response cache credential sentinel found unredacted in bundle" >&2
    exit 1
  fi

  # OTLP gRPC client key (telemetry.exporters.*.otlp.grpc.key) - only the Router 3 fixture
  # carries it, with key material distinct from the three tls.* keys, so its absence here is
  # evidence this key itself was masked rather than a copy of another masked key.
  if grep -q "AwEHoUQDQgAEqU8Us1ADy03O5lJj0Cp25AbJGjD" "$CONFIGMAP_JSON"; then
    echo "OTLP gRPC TLS private key found unredacted in bundle" >&2
    exit 1
  fi

  # Header values redaction tests - only redaction-testing-router-config.yaml carries these
  # (see base-router-config.yaml for why: this schema changed incompatibly across versions).
  if grep -qE "SENTINEL_HEADER_INSERT_VALUE|SENTINEL_HEADER_INSERT_DEFAULT|SENTINEL_HEADER_PROPAGATE_DEFAULT" "$CONFIGMAP_JSON"; then
    echo "Header plugin literal value sentinel found unredacted in bundle" >&2
    exit 1
  fi
  grep -q "x-sentinel-static" "$CONFIGMAP_JSON"       # header names survive
  grep -q "x-sentinel-frombody" "$CONFIGMAP_JSON"
  grep -q "x-sentinel-source-header" "$CONFIGMAP_JSON"

  # Response cache invalidation shared_key (specs/collection/data_sanitization/response_cache_invalidation_key.md) -
  # block-style, quoted, and flow-style values. Only redaction-testing-router-config.yaml carries
  # these: response_cache doesn't exist in the older routers the base matrix covers.
  if grep -qE "SENTINEL_RESPONSE_CACHE_SHARED_KEY" "$CONFIGMAP_JSON"; then
    echo "response_cache invalidation shared_key sentinel found unredacted in bundle" >&2
    exit 1
  fi
  grep -q "ttl: 120s" "$CONFIGMAP_JSON"  # non-secret sibling field survives
  grep -q "invalidation:" "$CONFIGMAP_JSON"
  # Each of the four set keys (block, quoted, flow, and last line with no trailing newline) must
  # carry the mask, spliced in where the value was.
  MASKED_KEYS=$(grep -oE 'shared_key: (\\")?\*\*\*HIDDEN\*\*\*' "$CONFIGMAP_JSON" | wc -l)
  [ "$MASKED_KEYS" -eq 4 ] || { echo "expected 4 masked shared_keys, got $MASKED_KEYS" >&2; exit 1; }
  # The sibling `enabled` survives next to a masked block-style key.
  grep -qE 'invalidation:\\n +enabled: true\\n +shared_key: \*\*\*HIDDEN\*\*\*' "$CONFIGMAP_JSON"
  # An empty shared_key is the schema default and means "unset", so it must not be mangled.
  grep -qF 'shared_key: \"\"' "$CONFIGMAP_JSON"
fi

tar tzf /tmp/bundle.tar.gz > /tmp/bundle-contents.txt
{
  echo "Bundle retrieved and verified. Contents:"
  cat /tmp/bundle-contents.txt
} | tee "$RTF_OUTPUT"
