#!/usr/bin/env bash
# Builds the `mode: job` image from this checkout and makes it available to the kind cluster, so
# the job-mode chainsaw tests run the code under test rather than a published image.
#
# Usage: load_job_image.sh <image:tag>
set -euo pipefail

IMAGE="${1:?usage: load_job_image.sh <image:tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Local runs (`mise run kind-up`) and CI (helm/kind-action) create clusters with different
# names so use KIND_CLUSTER_NAME if it's set and otherwise the first cluster kind lists.
CLUSTER="${KIND_CLUSTER_NAME:-}"
if [ -z "$CLUSTER" ]; then
  CLUSTER="$(kind get clusters | head -1)"
fi
[ -n "$CLUSTER" ] || { echo "FAIL: no kind cluster found to load $IMAGE into" >&2; exit 1; }

docker build -q -t "$IMAGE" "$ROOT/router-diagnostics-job-image"

if kind load docker-image "$IMAGE" --name "$CLUSTER"; then
  exit 0
fi

# Some kind releases can't read a newer containerd's config, so import the image into the
# node's containerd directly.
echo "kind load failed; importing $IMAGE into $CLUSTER-control-plane with ctr" >&2
docker save "$IMAGE" | docker exec -i "$CLUSTER-control-plane" ctr -n k8s.io images import -
