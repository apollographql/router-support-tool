# Data Collected

The default collection spec is grounded in a TSH ticket analysis of the past year's support tickets and feedback from support and router engineers.

## What the base spec collects

These items are collected in the base spec and address the most common first-round support asks. The table below documents what is collected, how, and the permissions each collector needs. This is designed to be shared directly with customers — a platform team can review it, grant the access required for the collectors they want, and understand exactly what each one provides and what's lost if they decline it. Nothing is collected that isn't listed here.

The base spec runs entirely externally — no `exec`-based collectors. See `specs/architecture.md` → Specs for why heavier operations belong in their own spec instead of growing this one.

This spec declares collectors and redactors only. **The base spec ships no analyzers** — the bundle is raw material for a support engineer, not a diagnosis.

Every bundle also carries a `meta.json` recording what the tool was configured to do — see `specs/collection/meta_json.md`. It cannot record why any given section came up empty on its own; that requires reasoning from the bundle directly.

Collector names follow the conventions in `specs/collection/collector_naming.md`, which also lists the assigned name for every collector below.

References to "the official Apollo router Helm chart" are pinned to `v2.17.0`; troubleshoot.sh is pinned to `v0.120.0` — see `specs/deployment/v1/v1.md` → Collection engine version.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| Pod status, restart counts, resource limits | k8s API | `clusterResources` collector | API server CPU | Whether pods are healthy, restart count, resource limits configured | k8s control plane | **Must be scoped with `namespaces: [<namespace>]`** — this collector defaults to every namespace in the cluster, and it collects ConfigMaps with their full `data`. See `specs/deployment/v1/v1.md` → Deployment tiers. |
| Runtime logs | Container log stream | `logs` collector | Network bandwidth | Recent router output, plus crash output from the previous container when one exists | Cluster network | Collected per pod, captures all containers in the pod (including proxy/mesh sidecars). **Previous-container logs are always collected**, written to `<name>-previous.log` — not an opt-in. How far back and how much is bounded by `logs.maxAge` / `logs.maxLines`, defined in `specs/deployment/v1/v1.md` → Chart values |
| Full Prometheus metrics snapshot | Router metrics endpoint | `http` collector | Network, router HTTP handler | Complete operational metrics — request rates, error rates, latency, traffic shaping state | Router network | Requires Prometheus endpoint enabled in `router.yaml`. See [Prometheus metrics: fixed port, tier-dependent](#prometheus-metrics-fixed-port-tier-dependent) below. |
| Sanitized `router.yaml` | ConfigMap holding the rendered config | `helm` + `configMap` collectors | API server CPU | Full router configuration — traffic shaping, timeouts, plugins, feature flags | k8s control plane | Captures config as written, not effective config (env-var overrides not included). Custom redactors strip JWT keys, auth config, and inline secrets. See [`router.yaml` capture](#routeryaml-capture) below. |
| `Router deployment env vars: APOLLO_GRAPH_REF, APOLLO_ROUTER_OFFICIAL_HELM_CHART` | Pod spec (`spec.containers[].env`) | `clusterResources` collector | API server CPU — no additional call, this data is already in the pod list | Graph ref for bundle tagging, whether the router was deployed via Apollo's official Helm chart | k8s control plane | Read from the declared pod spec, **not** by exec — see [Router env vars](#router-env-vars) below. `APOLLO_KEY` is never collected — it's structurally isolated in a separate Secret no collector reads. |
| Router version | Container image tag | `clusterResources` collector | API server CPU | Router version for bundle tagging | k8s control plane |  |
| Not collected: Redis health | Redis directly | `redis` collector | — | Would have given reachability (`isConnected`) and Redis server `version` — not latency | — | **Not in the base spec.** The collector requires an inline connection URI that no tier can supply safely. See [Redis health: not collected](#redis-health-not-collected) below. Redis errors still appear in router logs, and the Redis config block still appears in the collected `router.yaml` |

### `router.yaml` capture

Two collectors run unconditionally to capture configuration, because no single mechanism works across every supported deployment tier:

- **`helm` collector** (`collectValues: true`) — reads the Helm release values. Populates when the customer deployed via Helm; captures the values layer, which may or may not equal the fully rendered config depending on chart structure.
- **`configMap` collector** — reads the ConfigMap holding the rendered `configuration.yaml` directly, targeted by label selector (`app.kubernetes.io/name=router`) rather than by an exact ConfigMap name. This is what makes it work without knowing the customer's Helm release name in advance.

Both run in every collection. Whichever mechanism matches the customer's deployment populates; the other returns empty — consistent with the base spec's general graceful-degradation behavior.

For the **official Apollo router Helm chart**, the `configMap` collector succeeds directly by label, with no customer-supplied release name, selector, or ConfigMap name required. For **other Helm-based deployments**, the `helm` collector is more likely to succeed, since it doesn't depend on the official chart's labeling convention. For **raw-manifest or other custom deployments**, the customer supplies the ConfigMap name and pod selector as chart values instead — see `specs/deployment/v1/v1.md` → Chart values.

**Each router release in a namespace gets its own file.** Label-based targeting matches every ConfigMap with `app.kubernetes.io/name=router`, so a namespace running more than one router release (one per graph, for example) has every release's config collected, each in its own separately-named file — not silently dropped or overwritten, but not narrowed to just the one the customer meant to diagnose either. See `specs/collection/meta_json.md` → Multiple router releases in one namespace.

### Where graph schema/SDL actually lands

Schema/SDL is the one redaction customers can configure: included by default, with opt-out via the `redaction.includeSchema` chart value — see `specs/deployment/v1/v1.md` → Chart values. Everything else the base spec redacts is fixed, with no customer configuration.

There is no dedicated schema collector. Schema/SDL, when the chart puts it in the cluster at all, lands in a separate ConfigMap (`<release>-supergraph`), distinct from the main config ConfigMap, and only renders when the customer sets `.Values.supergraphFile` — customers on managed federation never populate it, so schema is absent regardless of `redaction.includeSchema` in that case. It carries the router chart's standard label, so it's swept up by the same `clusterResources` collection as everything else in the namespace, landing at `cluster-resources/configmaps/<namespace>.json` alongside the main config ConfigMap.

### Router env vars

**The base spec contains no `exec` collector.** `APOLLO_GRAPH_REF` and `APOLLO_ROUTER_OFFICIAL_HELM_CHART` are read from the pod spec that `clusterResources` already collects, rather than by exec'ing into the router container. This keeps the base spec entirely external — no `pods/exec` RBAC, and collection is unaffected by container health, which matters most on exactly the OOM-killed or crash-looping router a bundle exists to diagnose.

The one real cost: pod specs show env vars as *declared*, not *resolved*, so a value supplied indirectly (`valueFrom`/`envFrom`) shows only the reference, not the value. In practice this doesn't bite for the common case — neither variable's standard chart field supports indirection — and where a customer does route a value through a Secret via the chart's `extraEnvVars` escape hatch, respecting that indirection rather than resolving it is the correct behavior for a tool whose central promise is that it's safe to run.

### Prometheus metrics: fixed port, tier-dependent

The `http` collector targets the metrics endpoint at a **fixed port** (`9090`, confirmed from the official chart's `values.yaml`), not a port discovered from customer config — there's no discovery mechanism for an HTTP target the way the ConfigMap collectors can fall back to labels.

Three settings are load-bearing for this to return anything:

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the bind address. Binding to loopback means an external scrape can't reach it no matter what port the collector targets.
- `serviceMonitor.enabled: true` — the chart only adds a `metrics` port to the Service inside this flag. Without it, the Service has no `metrics` port at all, regardless of whether the exporter itself is on and reachable.

If any of the three is off or misconfigured, the collector returns empty; the rest of the bundle is unaffected. For raw-manifest and custom deployments, the port can't be inferred at all, so this section is empty by design in v1.

### Redis health: not collected

**The `redis` collector is not included in the base spec.** It requires an inline connection URI, and nothing can supply one safely — the collector has no Secret/ConfigMap reference option for the URI itself, and the official chart has no Redis-related values to fall back on (unlike the metrics port).

What's lost is narrower than it first appears: connectivity (`isConnected`) and a version string — not latency. Redis errors still appear in router logs, the Redis config block still appears in the collected `router.yaml` (across whichever of the router's three independent Redis-backed caches the customer has enabled), and cache metrics come from the Prometheus scrape when enabled.

### Namespace scoping is mandatory, not a default

`clusterResources`, `logs`, and `configMap` (when targeted by selector) all treat an empty namespace as "every namespace in the cluster" — standard Kubernetes list-call behavior, not something specific to troubleshoot.sh. Left unscoped, `clusterResources` in particular collects ConfigMaps with their full `data` across the entire cluster, not just the router's namespace — pulling unrelated teams' application config into a bundle the customer may share with Apollo.

The spec sets the namespace explicitly on all three (field names differ: `clusterResources` takes a `namespaces` list, `logs`/`configMap` take a singular `namespace` string). See `specs/deployment/v1/v1.md` → Deployment tiers for how the chart wires the required value into each. The raw-manifest tier's name-targeted `configMap` is the one exception — an unset namespace there falls back to the kubeconfig context's namespace rather than sweeping the cluster, a narrower failure but still not something to rely on.

### Memory and CPU information collected

Memory is the most nuanced collection area, because different levels of granularity require fundamentally different mechanisms. What the base spec collects is sufficient to **detect, confirm, and characterize** a memory problem: is memory growing, how fast, how close to the limit, and did the kernel already kill the container. It does not answer *which code path is leaking* — that needs jemalloc heap profiling via the router's diagnostics plugin, out of scope for the base spec.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| `memory.workingSetBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | How much memory k8s counts against the limit — the OOM kill threshold | k8s control plane → kubelet | Per node, per pod, per container. \[1\] |
| `memory.rssBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Physical RAM in use | k8s control plane → kubelet | \[1\] |
| `memory.usageBytes`, `memory.availableBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Usage, and headroom remaining against the limit | k8s control plane → kubelet | \[1\] |
| `memory.pageFaults`, `memory.majorPageFaults` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Major faults indicate real paging pressure rather than growth alone | k8s control plane → kubelet | \[1\] |
| `cpu.usageNanoCores`, `cpu.usageCoreNanoSeconds` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | CPU consumed by the router container | k8s control plane → kubelet | \[1\] |
| `cpu.psi`, `memory.psi` (pressure stall information) | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Whether the container is *stalling* on CPU or memory | k8s control plane → kubelet | **Conditional, not guaranteed** — depends on Kubernetes version and the `KubeletPSI` feature gate. Treat absence as expected on an unknown-version cluster, not a defect. |
| Configured `resources.limits` / `requests` | Pod spec | `clusterResources` collector | API server CPU | What the usage numbers above should be compared against | k8s control plane | Already collected as part of the pod list |
| OOM kill **occurrences** | Kubernetes events (`OOMKilling`, evictions) | `clusterResources` collector | API server CPU | That OOM kills happened, when, and how often | k8s control plane | Per-occurrence record, retained as long as the cluster keeps events |
| OOM kill **last state** | Pod status `lastState.terminated.reason: OOMKilled`, `restartCount` | `clusterResources` collector | API server CPU | Whether the most recent restart was an OOM kill | k8s control plane | Survives event expiry, unlike the row above |
| Node `MemoryPressure` / `DiskPressure` conditions | Node objects | `clusterResources` collector | API server CPU | Whether the node itself is under pressure, distinguishing a router problem from a neighbour's | k8s control plane | |
| `process_resident_memory_bytes` | Router Prometheus endpoint | `http` collector | Network, router HTTP handler | Process-level RSS as the router sees it | Router network | Requires the Prometheus exporter enabled and reachably bound. |
| `process_cpu_seconds_total` | Router Prometheus endpoint | `http` collector | Network, router HTTP handler | CPU time consumed by the router process | Router network | Same conditions as the row above |
| **Not collected:** `container_cpu_throttled_seconds_total` | cAdvisor `/metrics/cadvisor` | — | — | Whether the container is hitting its CPU cgroup limit | — | No troubleshoot.sh collector reaches this endpoint. `cpu.psi` is a partial, cluster-dependent substitute. |
| **Not collected:** `container_oom_events_total` | cAdvisor `/metrics/cadvisor` | — | — | A cumulative OOM-event counter | — | The two OOM rows above cover the diagnostic need without it. |
| **Not collected:** heap dump `.prof` files | `experimental_diagnostics` plugin | — | — | Which code path / allocation site is holding memory | — | Would require in-container execution, which the base spec does not do. |
| **Not collected:** CPU flame graph / pprof | `pprof-rs` | — | — | Which code is consuming CPU | — | Requires router instrumentation; named future gap. |

**\[1\]** The Summary API reports per node, per pod, and per container. This assumes one router process per container — the standard k8s pattern.

**Only the kubelet Summary API is reachable** (`nodeMetrics`) — cAdvisor's richer `/metrics/cadvisor` endpoint has no troubleshoot.sh collector, and reaching it would require inlining a bearer token unsafely into the spec, the same problem that rules out a `redisUri` value.

#### RBAC: what `nodeMetrics` actually requires

`nodeMetrics` needs three separate grants to reach `/api/v1/nodes/<node>/proxy/stats/summary`:

- **`nodes` (list)** — to resolve node names when neither `nodeNames` nor `selector` is set.
- **`nodes/proxy` (get)** — required unconditionally by the API server for any request matching the `/nodes/{name}/proxy/{path}` URL pattern. This is a broad grant: Kubernetes' own RBAC good-practices documentation states it "provides access to privileged kubelet APIs that can retrieve container logs or execute and attach to pod processes... bypasses audit logging and admission control," and is explicitly "not a read-only permission." What this tool does with it is read-only, but the grant itself authorizes more than that one use, and it cannot be scoped to just the router's nodes.
- **`nodes/stats` (get)** — required separately by the kubelet's own authorization check, layered on top of `nodes/proxy`, not a substitute for it.

This grant buys pre-OOM memory trajectory for customers who haven't enabled the Prometheus exporter — the only other source for that signal. Declining `nodes/proxy` (and therefore `nodes/stats`) leaves intact: OOM occurrences and last state, restart counts, configured limits, and node pressure conditions; lost is container-level usage over time when Prometheus is off.

## Service mesh and proxy environments

Some customers run a service mesh or proxy (Istio, Linkerd, Envoy) as a sidecar alongside the router.

The proxy itself can be the root cause of what looks like a router problem — a throttled sidecar, mTLS failures, or circuit-breaking presenting as router latency. The `logs` collector captures every container in the pod, and the kubelet Summary API reports per-container figures, so a sidecar's own resource usage is visible alongside the router's.

**A mesh enforcing strict mTLS can block the Prometheus scrape**, the one collector that talks directly to a router port rather than through the API server or kubelet. When this happens the result is an empty section, not an error — collection degrades gracefully, and the rest of the bundle is unaffected. The collected `router.yaml` is what disambiguates a mesh-blocked scrape from a disabled or misconfigured exporter: if `prometheus.enabled: true` is present in the config and the section is still empty, something external to the exporter's own settings prevented the scrape.

Whether the `mode: job` pod joins the mesh is a deployment decision — see `specs/deployment/v1/v1.md` → Service mesh environments. The Job runs outside the mesh by default, matching `mode: local`'s behavior (also outside any mesh). `meta.json`'s `sidecar_injection_disabled` field records that fact but only rules out one cause; it doesn't fully attribute an empty metrics section on its own.
