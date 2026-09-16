#!/usr/bin/env sh
set -eux

sh "$ENV_SETUP_SCRIPT"

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

helm install router-diagnostics "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --set namespace="$NAMESPACE" \
  --set mode=job \
  --set job.image.repository=us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-docker/router-support-tool/router-diagnostics-test \
  --set job.image.tag=v0.134.0 \
  --set job.image.pullPolicy=IfNotPresent \
  --set job.storage.provider=url \
  --set job.storage.url.endpoint="http://mock-backend.${NAMESPACE}.svc.cluster.local:8080/bundle.tar.gz" \
  --wait --timeout=60s

kubectl wait --for=condition=complete job/router-diagnostics-job -n "$NAMESPACE" --timeout=120s

curl -sf "http://mock-backend.${NAMESPACE}.svc.cluster.local:8080/bundle.tar.gz" -o /tmp/bundle.tar.gz

# This only checks that a bundle showed up and is a valid tarball.
# TODO: Check meta.json accuracy, redaction, etc.
test -s /tmp/bundle.tar.gz
tar tzf /tmp/bundle.tar.gz > /tmp/bundle-contents.txt
grep -q "version.yaml" /tmp/bundle-contents.txt
grep -q "meta.json" /tmp/bundle-contents.txt

{
  echo "Bundle retrieved successfully. Contents:"
  cat /tmp/bundle-contents.txt
} | tee "$RTF_OUTPUT"
