#!/usr/bin/env bash
# Runs once at `helm plugin install`/`helm plugin update` time. Downloads a
# pinned support-bundle release into this plugin's own directory
set -euo pipefail

# renovate: datasource=github-releases depName=replicatedhq/troubleshoot
SUPPORT_BUNDLE_VERSION="0.134.1"

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

mkdir -p "$HELM_PLUGIN_DIR/bin"
curl -sSLf "https://github.com/replicatedhq/troubleshoot/releases/download/v${SUPPORT_BUNDLE_VERSION}/${ASSET}" \
  | tar xz -C "$HELM_PLUGIN_DIR/bin" support-bundle
chmod +x "$HELM_PLUGIN_DIR/bin/support-bundle"

echo "router-diagnostics: installed support-bundle v${SUPPORT_BUNDLE_VERSION}"
