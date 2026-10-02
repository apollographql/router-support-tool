#!/bin/sh
# Collects a router-diagnostics support bundle for mode: local. Caches a pinned
# support-bundle binary locally, then runs support-bundle against the cluster's
# discoverable specs.

# Usage: collect.sh --namespace <namespace>
set -eu

# renovate: datasource=github-releases depName=replicatedhq/troubleshoot
SUPPORT_BUNDLE_VERSION="0.134.1"

NAMESPACE=""

usage() {
  echo "usage: collect.sh --namespace <namespace>" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --namespace=*)
      NAMESPACE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unrecognized argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$NAMESPACE" ]; then
  echo "error: --namespace is required" >&2
  usage
  exit 1
fi

# Fail early if a required tool is missing
MISSING=""
for tool in kubectl curl; do
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

"$BIN" --load-cluster-specs --namespace "$NAMESPACE" --auto-update=false --interactive=false
