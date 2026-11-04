#!/usr/bin/env bash
# Fetches the bundle a `mode: job` collection uploaded to the test's mock backend and asserts on
# the kubelet stats in it (specs/collection/base_spec.md -> Kubelet stats collection).
#
# Usage: verify_job_mode_kubelet_stats.sh <namespace>
set -euo pipefail

NAMESPACE="${1:?usage: verify_job_mode_kubelet_stats.sh <namespace>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert_host_collector_diagnostics_redacted.sh
source "$HERE/assert_host_collector_diagnostics_redacted.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The bundle is left in the working directory as support-bundle-job-mode.tar.gz so CI can
# upload it for inspection.
OUT=support-bundle-job-mode.tar.gz
kubectl exec -n "$NAMESPACE" deploy/mock-backend -- python3 -c \
  "import sys, urllib.request; sys.stdout.buffer.write(urllib.request.urlopen('http://127.0.0.1:8080/bundle.tar.gz').read())" > "$OUT"
[ -s "$OUT" ] || fail "no bundle reached the mock backend"

EXTRACTED="$(mktemp -d)"
trap 'rm -rf "$EXTRACTED"' EXIT
tar xzf "$OUT" -C "$EXTRACTED"
DIR="$(find "$EXTRACTED" -maxdepth 1 -type d -name 'support-bundle-*' | head -1)"
[ -n "$DIR" ] || fail "no support-bundle-* directory in the uploaded bundle"

RUN_HOST="$DIR/host-collectors/run-host"
STATS_ROOT="$RUN_HOST/router-resource-usage/nodes"

# The memory and CPU signals the spec documents are present for the router container (the
# positive control: an empty section would look identical to success).
python3 -I "$HERE/assert_documented_memory_cpu_signals.py" "$DIR"

# The layout is mode: job's, with no node-metrics/.
[ ! -e "$DIR/node-metrics" ] || fail "node-metrics/ is in a mode: job bundle; the kubelet script should have replaced nodeMetrics"
# One <node-name>.json per node in nodes/.
STATS_FILES="$(find "$STATS_ROOT" -maxdepth 1 -type f -name '*.json' 2>/dev/null || true)"
[ -n "$STATS_FILES" ] || fail "no <node-name>.json files under $STATS_ROOT"

# A healthy run writes no named reasons because nothing is missing.
REASONS="$RUN_HOST/router-resource-usage.txt"
[ -e "$REASONS" ] || fail "$REASONS is missing"
[ ! -s "$REASONS" ] || fail "a healthy run wrote named reasons: $(cat "$REASONS")"

# Only the router's pods reach the bundle, not the other workloads on the node.
ROUTER_PODS="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=router -o jsonpath='{.items[*].metadata.name}')"
OTHER_PODS="$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v '^router-' || true)"
[ -n "$ROUTER_PODS" ] || fail "no router pod to compare the stats against"
[ -n "$OTHER_PODS" ] || fail "no non-router pod in $NAMESPACE, so the filtering check proves nothing"
while IFS= read -r file; do
  names="$(python3 -I -c 'import json, sys; print("\n".join(p["podRef"]["name"] for p in json.load(open(sys.argv[1]))["pods"]))' "$file")"
  [ -n "$names" ] || fail "$file lists no pods"
  while IFS= read -r name; do
    case " $ROUTER_PODS " in
      *" $name "*) ;;
      *) fail "$file lists $name, which is not one of the router's pods ($ROUTER_PODS)" ;;
    esac
  done <<< "$names"
  while IFS= read -r other; do
    if grep -q "\"$other\"" "$file"; then
      fail "$file contains $other, another workload on the node"
    fi
  done <<< "$OTHER_PODS"
done <<< "$STATS_FILES"

# The host-collector diagnostic sidecar is fully redacted: it carries the collecting pod's
# environment, so it must be masked.
assert_host_collector_diagnostics_redacted "$DIR"
INFO="$RUN_HOST/router-resource-usage-info.json"
[ -e "$INFO" ] || fail "no router-resource-usage diagnostic sidecar at $INFO"
[ "$(cat "$INFO")" = "***HIDDEN***" ] || fail "$INFO was not fully redacted"

# Neither a ServiceAccount token nor APOLLO_KEY appears anywhere in the bundle. The token the
# script sends to the kubelet must never be written down.
if grep -rEI 'eyJ[A-Za-z0-9_-]{10,}' "$DIR" > /dev/null; then
  fail "a JWT-shaped string (a ServiceAccount token?) is in the bundle: $(grep -rEIl 'eyJ[A-Za-z0-9_-]{10,}' "$DIR")"
fi
if grep -rEI 'Bearer [A-Za-z0-9._~+/=-]{20,}' "$DIR" > /dev/null; then
  fail "a bearer token is in the bundle: $(grep -rEIl 'Bearer [A-Za-z0-9._~+/=-]{20,}' "$DIR")"
fi

if grep -rq "APOLLO_KEY" "$DIR"; then
  fail "APOLLO_KEY found in bundle contents - this must never happen"
fi

echo "mode: job kubelet stats verified: $(echo "$STATS_FILES" | wc -l | tr -d ' ') node file(s), only the router's pods"
