#!/usr/bin/env sh
set -eux

NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"

router_pods() {
  kubectl get pods -n "$NAMESPACE" -l app=router -o jsonpath='{.items[*].metadata.name}'
}

router_config_path() {
  kubectl get pod "$1" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.router-config-path}'
}

router_config_degraded_path() {
  kubectl get pod "$1" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.router-config-degraded-path}'
}

# Overwrites one router pod's own config file in place with the degraded variant
misconfigure_metrics() {
  pod="$1"
  healthy_path=$(router_config_path "$pod")
  degraded_path=$(router_config_degraded_path "$pod")
  test -n "$healthy_path"
  test -n "$degraded_path"
  kubectl exec "$pod" -n "$NAMESPACE" -- cp "$degraded_path" "$healthy_path"
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
