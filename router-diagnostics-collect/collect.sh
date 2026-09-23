#!/bin/sh
# Collects a router-diagnostics support bundle for mode: local. Caches a pinned
# support-bundle binary locally, reads the target router-diagnostics release's
# namespace/selector/metricsPort values, resolves the router's Service, bridges its
# metrics port with a temporary kubectl port-forward, then runs support-bundle against
# the cluster's discoverable specs.
#
# Usage: collect.sh [-n|--namespace <release-namespace>] [release-name]
# Requires helm, kubectl, jq, and curl on PATH, and the router-diagnostics chart already
# installed (mode: local) - this reads that release's values, it doesn't install it.
set -eu

# renovate: datasource=github-releases depName=replicatedhq/troubleshoot
SUPPORT_BUNDLE_VERSION="0.134.1"

RELEASE_NAMESPACE="default"
RELEASE_NAME="router-diagnostics"

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)
      RELEASE_NAMESPACE="$2"
      shift 2
      ;;
    --namespace=*)
      RELEASE_NAMESPACE="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "usage: collect.sh [-n|--namespace <release-namespace>] [release-name]" >&2
      exit 0
      ;;
    *)
      RELEASE_NAME="$1"
      shift
      ;;
  esac
done

# --- Fail fast if a required tool is missing, rather than mid-run on whichever one
# happens to be invoked first. ---
MISSING=""
for tool in helm kubectl jq curl; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  echo "error: missing required tool(s):$MISSING - install them and re-run" >&2
  exit 1
fi

# --- Ensure the pinned support-bundle binary is cached locally. Named with its version
# so a Renovate bump downloads a fresh binary rather than silently reusing a stale one. ---
CACHE_DIR="${ROUTER_DIAGNOSTICS_CACHE_DIR:-$HOME/.router-diagnostics}"
BIN="$CACHE_DIR/bin/support-bundle-v${SUPPORT_BUNDLE_VERSION}"

if [ ! -x "$BIN" ]; then
  case "$(uname -s)" in
    Darwin) ASSET="support-bundle_darwin_all.tar.gz" ;;
    Linux)
      case "$(uname -m)" in
        arm64|aarch64) ASSET="support-bundle_linux_arm64.tar.gz" ;;
        *) ASSET="support-bundle_linux_amd64.tar.gz" ;;
      esac
      ;;
    *)
      echo "error: unsupported OS $(uname -s)" >&2
      exit 1
      ;;
  esac

  mkdir -p "$CACHE_DIR/bin"
  TMP_BIN="$CACHE_DIR/bin/.support-bundle-v${SUPPORT_BUNDLE_VERSION}.tmp"
  curl -sSLf "https://github.com/replicatedhq/troubleshoot/releases/download/v${SUPPORT_BUNDLE_VERSION}/${ASSET}" \
    | tar xz -O support-bundle > "$TMP_BIN"
  chmod +x "$TMP_BIN"
  mv "$TMP_BIN" "$BIN"
  echo "router-diagnostics: cached support-bundle v${SUPPORT_BUNDLE_VERSION}" >&2
fi

# --- Resolve the router-diagnostics release's values ---
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
# Raw-manifest/custom tier sets `metricsPort` when its exporter isn't on the official
# chart's default port and defaults to 9090.
METRICS_PORT=$(echo "$RELEASE_VALUES" | jq -r '.metricsPort // 9090')

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
  kubectl port-forward -n "$ROUTER_NAMESPACE" "svc/$SERVICE" "$METRICS_PORT:$METRICS_PORT" >"$PF_LOG" 2>&1 &
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

# --auto-update=false: support-bundle's root command self-updates by default (checks
# GitHub's latest release and replaces its own binary), which would silently override
# the version this script pins - see specs/deployment/v1/v1.md -> troubleshoot.sh
# support-bundle version.
"$BIN" --load-cluster-specs --namespace "$RELEASE_NAMESPACE" --auto-update=false
