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
test -s "$BUNDLE_DIR/router-metrics/result.json"                                # Prometheus scrape
find "$BUNDLE_DIR/router-logs" -name '*.log' -size +0 | grep -q .               # router container logs
find "$BUNDLE_DIR/cluster-resources/pods" -name '*.json' -size +0 | grep -q .   # pod listed by clusterResources
find "$BUNDLE_DIR/configmaps" -name '*.json' -size +0 | grep -q .               # router-config found by name/label

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
