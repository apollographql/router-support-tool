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
  router-recently-restarted)
    # Restart exactly one router pod's container in place (same pod, same name) and wait
    # for it to come back Ready. This is deliberately NOT `kubectl rollout restart` -
    # that replaces the pod entirely via the ReplicaSet, producing a brand-new pod with no
    # restart history at all, so there'd be nothing for `logs`'s previous-container
    # capture to find. Killing PID 1 inside the existing container (restartPolicy: Always)
    # is what actually produces a previous-container log within the same pod.
    set -- $(router_pods)
    pod="$1"
    # `kill` is a shell builtin, not a standalone binary - `kubectl exec ... -- kill 1`
    # execs "kill" directly with no shell involved, so it fails with "executable file not
    # found" on any image that doesn't separately ship procps' /bin/kill. Routing it
    # through `sh -c` is what actually gets the builtin.
    kubectl exec "$pod" -n "$NAMESPACE" -c router -- sh -c 'kill 1'
    # Wait for the container to actually restart before trusting readiness - checking
    # Ready right after `kill 1` can read a stale "True" from before the kubelet has
    # even observed the container exit, breaking out of the loop before the restart
    # (and the previous-container log it produces) has happened at all.
    for _ in $(seq 1 60); do
      restarts=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[?(@.name=="router")].restartCount}')
      [ "${restarts:-0}" -gt 0 ] && break
      sleep 1
    done
    [ "${restarts:-0}" -gt 0 ]
    # Now that the restart has actually happened, check that the pod is ready again.
    for _ in $(seq 1 60); do
      ready=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
      [ "$ready" = "True" ] && break
      sleep 1
    done
    [ "$ready" = "True" ]
    ;;
  *)
    echo "unknown or not-yet-implemented condition: $CONDITION" >&2
    exit 1
    ;;
esac
