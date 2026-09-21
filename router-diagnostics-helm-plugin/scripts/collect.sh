#!/bin/sh
# `helm router-diagnostics collect [release-name]`
set -eu

SUBCOMMAND="${1:-}"
if [ "$SUBCOMMAND" != "collect" ]; then
  echo "usage: helm router-diagnostics collect [release-name]" >&2
  exit 1
fi

RELEASE_NAME="${2:-router-diagnostics}"
# Helm parses -n/--namespace and exports it as HELM_NAMESPACE where the
# release lives, not necessarily where the router runs.
RELEASE_NAMESPACE="${HELM_NAMESPACE:-default}"

RELEASE_VALUES=$(helm get values "$RELEASE_NAME" -n "$RELEASE_NAMESPACE" -o json)
# Where the router itself runs, per the chart's own `namespace` value.
ROUTER_NAMESPACE=$(echo "$RELEASE_VALUES" | jq -r '.namespace // empty')
if [ -z "$ROUTER_NAMESPACE" ]; then
  echo "error: could not read .namespace from release '$RELEASE_NAME' in namespace '$RELEASE_NAMESPACE', is router-diagnostics installed there?" >&2
  exit 1
fi

# Raw-manifest/custom tier sets `selector` to its own pod label and falls back to
# the official Apollo Helm chart's own label.
SELECTOR=$(echo "$RELEASE_VALUES" | jq -r '.selector // "app.kubernetes.io/name=router"')

SVC_ERR=$(mktemp)
PF_LOG=$(mktemp)
PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -f "$SVC_ERR" "$PF_LOG"
}
trap cleanup EXIT INT TERM

if ! SERVICE=$(kubectl get svc -n "$ROUTER_NAMESPACE" -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>"$SVC_ERR"); then
  echo "error: kubectl get svc failed: $(cat "$SVC_ERR")" >&2
  exit 1
fi

if [ -z "$SERVICE" ]; then
  echo "warning: no Service labeled $SELECTOR found in namespace $ROUTER_NAMESPACE, router-metrics will fail with a connection error." >&2
else
  kubectl port-forward -n "$ROUTER_NAMESPACE" "svc/$SERVICE" 9090:9090 >"$PF_LOG" 2>&1 &
  PF_PID=$!

  READY=0
  for _ in $(seq 1 30); do
    if grep -q "Forwarding from" "$PF_LOG" 2>/dev/null; then
      READY=1
      break
    fi
    sleep 0.5
  done

  if [ "$READY" -ne 1 ]; then
    echo "warning: port-forward to $SERVICE:9090 never became ready, router-metrics collector will fail with a connection error" >&2
    echo "--- kubectl port-forward output ---" >&2
    cat "$PF_LOG" >&2
  fi
fi

"$HELM_PLUGIN_DIR/bin/support-bundle" --load-cluster-specs --namespace "$RELEASE_NAMESPACE"
