#!/usr/bin/env bash
# Shared assertion tying specs/collection/base_spec.md's "Memory and CPU information
# collected" table to what a bundle actually contains. A signal the spec documents but the
# bundle lacks fails here, so the spec cannot promise data that is never collected (the
# router's Prometheus endpoint, for one, serves no process_* metrics).
#
# The signals are read from the spec's table, not listed here:
#   - rows whose Source is "Router Prometheus endpoint" must appear in every per-pod scrape
#     under host-collectors/run-host/router-metrics/pods/
#   - rows whose Source is "kubelet Summary API" must be non-null on the router container
#     in node-metrics/*.json
#
# Usage: source this file, then call assert_documented_memory_cpu_signals <bundle-dir>
# Only for bundles collected with nodeMetrics enabled; job-mode scenarios that decline it
# (job.collectNodeMetrics=false) cannot satisfy the kubelet half.
# MEMORY_CPU_SPEC_FILE points the check at another copy of the spec (to test the check).

# Backticked signal names that the spec's table attributes to the given Source cell. A
# shorthand like `_active` after `apollo_router_jemalloc_allocated` expands against the
# previous full name's prefix (apollo_router_jemalloc_active).
_documented_signals() {
  local spec="$1" source="$2"
  awk -F'|' -v src="$source" 'index($3, src) { print $2 }' "$spec" \
    | { grep -o '`[^`]*`' || true; } | tr -d '`' \
    | {
      local base="" tok
      while IFS= read -r tok; do
        case "$tok" in
          _*) echo "${base}${tok}" ;;
          *) echo "$tok"; base="${tok%_*}" ;;
        esac
      done
    }
}

assert_documented_memory_cpu_signals() {
  local dir="$1"
  local spec="${MEMORY_CPU_SPEC_FILE:-$(dirname "${BASH_SOURCE[0]}")/../../../specs/collection/base_spec.md}"
  local f sig nm count=0 saw=false

  _memory_cpu_fail() {
    echo "FAIL: $1" >&2
    exit 1
  }

  [ -f "$spec" ] || _memory_cpu_fail "spec not found at $spec"

  local prom kube
  prom=$(_documented_signals "$spec" "Router Prometheus endpoint")
  [ -n "$prom" ] || _memory_cpu_fail "no 'Router Prometheus endpoint' signals found in $spec - did the Memory and CPU table change shape?"
  kube=$(_documented_signals "$spec" "kubelet Summary API")
  [ -n "$kube" ] || _memory_cpu_fail "no 'kubelet Summary API' signals found in $spec - did the Memory and CPU table change shape?"

  local pods_dir="$dir/host-collectors/run-host/router-metrics/pods"
  while IFS= read -r f; do
    count=$((count + 1))
    while IFS= read -r sig; do
      grep -Eq "^${sig}(\{| )" "$f" \
        || _memory_cpu_fail "$(basename "$f"): the spec documents $sig as served by the router's Prometheus endpoint, but it is not in the scrape"
    done <<< "$prom"
  done < <(find "$pods_dir" -maxdepth 1 -name '*.txt' -type f 2>/dev/null)
  [ "$count" -gt 0 ] || _memory_cpu_fail "no per-pod scrape files under $pods_dir to check the documented Prometheus signals against"

  for nm in "$dir"/node-metrics/*.json; do
    [ -e "$nm" ] || _memory_cpu_fail "no node-metrics/*.json in the bundle, but the spec documents kubelet memory/CPU signals"
    jq -e '[.pods[]?.containers[]? | select(.name == "router")] | length > 0' "$nm" > /dev/null || continue
    saw=true
    while IFS= read -r sig; do
      jq -e --arg p "$sig" '
        [.pods[]?.containers[]? | select(.name == "router")]
        | all(.[]; getpath($p | split(".")) != null)' "$nm" > /dev/null \
        || _memory_cpu_fail "$(basename "$nm"): the spec documents $sig for the router container, but it is missing (psi also needs the KubeletPSI feature gate, see testing/kind-config.yaml)"
    done <<< "$kube"
  done
  [ "$saw" = true ] || _memory_cpu_fail "no container named router in any node-metrics/*.json"
}
