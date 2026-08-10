# Data Collected

The default collection spec is grounded in a TSH ticket analysis of the past year's support tickets and feedback from support and router engineers. The ticket analysis revealed a consistent pattern: the highest-leverage data to collect is not exotic, it's the routine data that support has to ask for in the first round of every ticket and almost never receives upfront. Version, graph ID, full config. These items eliminate the first two or three rounds of back-and-forth from virtually every ticket.

## What the base spec collects

These items are collected in the base spec and address the most common first-round support asks. The table below documents what is collected, how, and the permissions each collector needs. This is designed to be shared directly with customers — a platform team can review it, grant the access required for the collectors they want, and understand exactly what each one provides and what's lost if they decline it. Nothing is collected that isn't listed here.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| Pod status, restart counts, resource limits | k8s API | `clusterResources` collector | API server CPU | Whether pods are healthy, restart count, resource limits configured | k8s control plane |  |
| Runtime logs | Container log stream | `logs` collector | Network bandwidth | Recent router output, crash output from previous container if enabled | Cluster network | Collected per pod, captures all containers in the pod (including proxy/mesh sidecars) Previous container logs opt-in via `values.yaml` |
| Full Prometheus metrics snapshot | Router metrics endpoint | `http` collector | Network, router HTTP handler | Complete operational metrics — request rates, error rates, latency, traffic shaping state | Router network | Requires Prometheus endpoint enabled in `router.yaml`. See [Prometheus metrics: fixed port, tier-dependent](#prometheus-metrics-fixed-port-tier-dependent) below. |
| Redis health | Redis directly | `redis` collector | One Redis connection | Redis connectivity and latency | Redis | Fails gracefully if Redis is at `maxclients` capacity |
| Sanitized `router.yaml` | ConfigMap holding the rendered config | `helm` + `configMap` collectors | API server CPU | Full router configuration — traffic shaping, timeouts, plugins, feature flags | k8s control plane | Captures config as written, not effective config (env-var overrides not included). Custom redactors strip JWT keys, auth config, and inline secrets. See [`router.yaml` capture: two collectors, deployment-tier dependent](#routeryaml-capture-two-collectors-deployment-tier-dependent) below. |
| `Router deployment env vars: APOLLO_GRAPH_REF, APOLLO_ROUTER_OFFICIAL_HELM_CHART` | Pod env vars | `exec` collector | Tiny CPU, single exec call reading all env vars | Graph ref for bundle tagging, whether the router was deployed via Apollo's official Helm chart | Router container cgroup | None of the values collected are sensitive. `APOLLO_KEY` is never read or included under any circumstances |
| Router version | Container image tag | `clusterResources` collector | API server CPU | Router version for bundle tagging | k8s control plane |  |

### `router.yaml` capture: two collectors, deployment-tier dependent

Two collectors run unconditionally to capture configuration, because no single mechanism works across every supported deployment tier:

- **`helm` collector** (`collectValues: true`) — reads the Helm release values. Populates when the customer deployed via Helm; captures the values layer, which may or may not equal the fully rendered config depending on chart structure.
- **`configMap` collector** — reads the ConfigMap holding the rendered `configuration.yaml` directly, targeted by label selector (`app.kubernetes.io/name=router`) rather than by an exact ConfigMap name. This is what makes it work without knowing the customer's Helm release name in advance.

Both run in every collection. Whichever mechanism matches the customer's deployment populates; the other returns empty — consistent with the base spec's general graceful-degradation behavior.

For the **official Apollo router Helm chart**, the `configMap` collector succeeds directly: the chart's ConfigMap carries the standard `app.kubernetes.io/name=router` label, and the ConfigMap name is always the Helm release name, so label-based targeting finds it with no customer-supplied release name, selector, or ConfigMap name required.

For **other Helm-based deployments**, the `helm` collector is more likely to succeed, since it does not depend on the deployment following the official chart's specific labeling convention.

Neither collector can succeed for raw-manifest or other custom deployments without a customer-supplied ConfigMap name or selector — which is why that deployment tier is not supported in v1 (see `specs/deployment/`).

### Prometheus metrics: fixed port, tier-dependent

The `http` collector targets the metrics endpoint at a **fixed port confirmed from rendering the official Apollo router Helm chart** (`:9090/metrics`), not a port discovered from the customer's configuration. This port cannot be inferred from customer-supplied config the way the ConfigMap collectors above can fall back to labels — there is no equivalent discovery mechanism for an HTTP target, so the base spec relies on the official chart's known default.

For the **official Apollo router Helm chart**: this succeeds whenever the customer has enabled the Prometheus exporter in `router.yaml` (`telemetry.exporters.metrics.prometheus.enabled: true`). If they haven't, the collector returns empty; the rest of the bundle is unaffected.

For **other supported deployment tiers** (Apollo Operator): if the deployment's metrics port differs from `9090`, this collector returns empty rather than failing. Metrics collection currently depends on the deployment matching the official chart's port convention.

Subgraph health checks and OTel endpoint reachability were considered for the base spec and dropped for v1, for the same underlying reason: both would require an HTTP target (a subgraph URL, an OTel collector endpoint) that is customer-specific and has no chart-level default to fall back on, unlike the metrics port. Subgraph health is instead inferable from the router's own `apollo.router.operations.fetch*` metrics, which are already captured by this same Prometheus scrape when enabled.

### Memory and CPU information collected

Note: Memory is the most nuanced collection area because different levels of granularity require fundamentally different mechanisms. What we are collecting as part of the base spec should be sufficient to detect, confirm, and characterize a memory problem. It answers: is memory growing, how fast, how close to the limit, is it heap growth. It does not answer: which specific code path is leaking. That granularity requires jemalloc heap profiling via the diagnostics plugin. We will not be including jemalloc heap profiling as part of v1 of the support tool.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| `container_memory_working_set_bytes` | cAdvisor / k8s metrics API |  `containerMetrics` collector |  API server CPU | How much memory k8s counts against the limit — the OOM kill threshold |  k8s control plane | cAdvisor metrics are labelled per container per pod and correctly separate data across all router pods in a fleet. This assumes one router process per container — the standard k8s deployment pattern. For non-standard topologies where multiple processes share a container, cAdvisor metrics are aggregated at the container level and cannot distinguish between individual processes. \[1\] |
| `container_memory_rss` | cAdvisor / k8s metrics API |  `containerMetrics` collector |  API server CPU | Physical RAM in use | k8s control plane | [See \[1\]](#bookmark=id.2r6vqnoi88ik) |
| `container_oom_events_total` | cAdvisor / k8s metrics API |  `containerMetrics` collector |  API server CPU  | How many OOM kills have occurred — customers often don't know |  k8s control plane | [See \[1\]](#bookmark=id.2r6vqnoi88ik) |
| `process_resident_memory_bytes` | Router Prometheus endpoint | `http` collector | Network, router HTTP handler |    Process-level RSS |  Router network | Requires Prometheus endpoint enabled. Subject to the fixed-port caveat above. |
| `container_cpu_usage_seconds_total` | cAdvisor / k8s metrics API |  `containerMetrics` collector |  API server CPU | CPU time consumed by the router container |  k8s control plane | Labelled per pod and container — fleet-wide |
| `container_cpu_throttled_seconds_total` | cAdvisor / k8s metrics API |  `containerMetrics` collector |  API server CPU | Whether the container is hitting its CPU cgroup limit |  k8s control plane | CPU problems are more often about hitting cgroup limits than raw CPU exhaustion |
| `process_cpu_seconds_total` | Router Prometheus endpoint |  `http` collector |  Network, router HTTP handler | CPU time consumed by the router process |  Router network | Requires Prometheus endpoint enabled. Subject to the fixed-port caveat above. |
| Not collected: `Heap dump .prof files` | `experimental_diagnostics` plugin | `exec` collector | — | Which code path / allocation site is holding memory |  Router container cgroup | Not collected — requires `experimental_diagnostics` enabled and `supported.rs:219` fix |
| Not collected: CPU flame graph / pprof | `pprof-rs`  |  — |  — | Which code is consuming CPU |  — | Not collected — requires router instrumentation, named future gap |

## Service mesh and proxy environments

Some customers run a service mesh or proxy (Istio, Linkerd, Envoy) as a sidecar alongside the router. Two things to note:

* The proxy itself can be the root cause of what looks like a router problem — a throttled or OOMing sidecar, mTLS failures, or Envoy circuit-breaking present as router latency or subgraph failures. To catch this, the `logs` and `containerMetrics` collectors capture all containers in the pod, not just the router.
