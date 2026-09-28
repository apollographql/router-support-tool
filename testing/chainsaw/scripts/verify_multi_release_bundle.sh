#!/usr/bin/env bash
# Installs router-diagnostics (mode: local) into a namespace containing two ConfigMaps
# labeled app.kubernetes.io/name=router (standing in for two separate router releases,
# e.g. one per graph), and checks that the configMap collector captures both as
# separately-named files, each with its own content intact - see
# specs/collection/base_spec.md -> "router.yaml capture" and
# specs/collection/meta_json.md -> Multiple router releases in one namespace.
#
# Usage: verify_multi_release_bundle.sh <namespace> <chart-path> <collect-script-path>
# chart-path/collect-script-path are not repo-root-relative - see the calling
# chainsaw-test.yaml, which runs this with the test's own directory as its working directory.
set -euo pipefail

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

# Default selector matches both ConfigMaps' app.kubernetes.io/name=router label.
"$COLLECT_SCRIPT" --namespace "$NAMESPACE"

BUNDLE=$(ls -t support-bundle-*.tar.gz | head -1)
DIR="${BUNDLE%.tar.gz}"
tar xzf "$BUNDLE"

CONFIG_DIR="$DIR/configmaps/$NAMESPACE"
ALPHA="$CONFIG_DIR/router-alpha.json"
BETA="$CONFIG_DIR/router-beta.json"

[ -f "$ALPHA" ] || fail "router-alpha.json missing - expected one file per matched ConfigMap"
[ -f "$BETA" ] || fail "router-beta.json missing - expected one file per matched ConfigMap"

jq -e '.data["router.yaml"] | contains("release: alpha")' "$ALPHA" > /dev/null \
  || fail "router-alpha.json doesn't contain its own release's config"
jq -e '.data["router.yaml"] | contains("release: beta")' "$BETA" > /dev/null \
  || fail "router-beta.json doesn't contain its own release's config"

# Cross-check the two weren't swapped or merged into each other.
jq -e '.data["router.yaml"] | contains("release: beta") | not' "$ALPHA" > /dev/null \
  || fail "router-alpha.json unexpectedly contains router-beta's content"
jq -e '.data["router.yaml"] | contains("release: alpha") | not' "$BETA" > /dev/null \
  || fail "router-beta.json unexpectedly contains router-alpha's content"

echo "All checks passed."
