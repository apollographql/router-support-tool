#!/usr/bin/env sh
set -eux

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

# Put the environment into the shape this matrix variant needs.
case "$CONDITION" in
  healthy)
    ;;
  *)
    echo "unknown or not-yet-implemented condition: $CONDITION" >&2
    exit 1
    ;;
esac
