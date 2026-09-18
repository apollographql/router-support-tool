#!/usr/bin/env sh
set -eux

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

router_pods() {
  kubectl get pods -n "$NAMESPACE" -l app=router -o jsonpath='{.items[*].metadata.name}'
}


# Finds the exact in-container config path from the pod's own spec.
find_router_config_path() {
  pod="$1"
  i=0
  while :; do
    arg=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath="{.spec.containers[0].args[$i]}")
    [ -n "$arg" ] || return 1
    if [ "$arg" = "-c" ]; then
      i=$((i + 1))
      kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath="{.spec.containers[0].args[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
}

# Overwrites one router pod's own config file in place with the degraded variant.
misconfigure_metrics() {
  pod="$1"
  router_config_path=$(find_router_config_path "$pod")
  test -n "$router_config_path"
  kubectl exec -i "$pod" -n "$NAMESPACE" -- cp /dev/stdin "$router_config_path" < "$ROUTER_CONFIG_METRICS_DISABLED"
}

# Put the environment into the shape this matrix variant needs.
case "$CONDITION" in
  healthy)
    ;;
  some-metrics-misconfigured)
    set -- $(router_pods)
    misconfigure_metrics "$1"
    ;;
  all-metrics-misconfigured)
    for pod in $(router_pods); do
      misconfigure_metrics "$pod"
    done
    ;;
  *)
    echo "unknown or not-yet-implemented condition: $CONDITION" >&2
    exit 1
    ;;
esac
