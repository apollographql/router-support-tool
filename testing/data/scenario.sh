#!/usr/bin/env sh
set -eux

sh "$ENV_SETUP_SCRIPT"

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

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
  --set job.image.repository=us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-docker/router-support-tool/router-diagnostics-test \
  --set job.image.tag=v0.134.0 \
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
# Every router pod should be Running with zero restarts by this point.
jq -e '[.items[] | select(.metadata.labels.app == "router") | .status.phase] | all(. == "Running")' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"
jq -e '[.items[] | select(.metadata.labels.app == "router") | .status.containerStatuses[0].restartCount] | all(. == 0)' "$BUNDLE_DIR/cluster-resources/pods/$NAMESPACE.json"

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

# configMap collector: assert the collected router.yaml matches the config in the ConfigMap.
# $ROUTER_CONFIG is the same base-router-config.yaml baked into router-manifest.yaml's static ConfigMap,
jq -j '.data["router.yaml"]' "$BUNDLE_DIR/configmaps/$NAMESPACE/router-config.json" > /tmp/collected-router-config.yaml
diff "$ROUTER_CONFIG" /tmp/collected-router-config.yaml

# Guard against the bug if the Service selector doesn't match,
# the collector never reaches a router at all and returns an error.
if grep -q 'router-metrics-host-not-found' "$BUNDLE_DIR/router-metrics/result.json"; then
  echo "router-metrics collector never resolved the router Service - selector/label mismatch?" >&2
  exit 1
fi

case "$CONDITION" in
  all-metrics-misconfigured)
    # Every router has prometheus.enabled=false, so the scrape should genuinely fail -
    # no metrics text anywhere in the result.
    ! grep -q '# HELP' "$BUNDLE_DIR/router-metrics/result.json"
    ;;
  *)
    # At least one router still has prometheus.enabled=true, so the scrape should return
    # real metrics text, not just a non-empty error envelope.
    grep -q '# HELP' "$BUNDLE_DIR/router-metrics/result.json"
    ;;
esac

# --- APOLLO_KEY must never be collected ---
if grep -rq "APOLLO_KEY" "$BUNDLE_DIR"; then
  echo "APOLLO_KEY found in bundle contents - this must never happen" >&2
  exit 1
fi

tar tzf /tmp/bundle.tar.gz > /tmp/bundle-contents.txt
{
  echo "Bundle retrieved and verified. Contents:"
  cat /tmp/bundle-contents.txt
} | tee "$RTF_OUTPUT"
