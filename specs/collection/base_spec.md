# Data Collected

The default collection spec is grounded in a TSH ticket analysis of the past year's support tickets and feedback from support and router engineers.

## What the base spec collects

These items are collected in the base spec. The table below is designed to be shared with customers so a platform team can review it, grant the access required for the collectors they want, and understand exactly what each one provides and what's lost if they decline it. Nothing is collected that isn't listed here.

Every bundle also carries a `meta.json` recording what the tool was configured to do, see `specs/collection/meta_json.md` for more details.

Collector names follow the conventions in `specs/collection/collector_naming.md`, which also lists the assigned name for every collector below.

References to "the official Apollo router Helm chart" are pinned to `v2.17.0` and.  troubleshoot.sh is pinned to `v0.120.0` — see `specs/deployment/v1/v1.md` → Collection engine version.

| Source | Signal | Collected via | What it tells you | Resource consumed | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| k8s API | Pod status, restart counts, resource limits | `clusterResources` collector | Whether pods are healthy, restart count, resource limits configured | API server CPU | k8s control plane | **Must be scoped with `namespaces: [<namespace>]`** — this collector defaults to every namespace in the cluster, and it collects ConfigMaps with their full `data`. |
| Container image tag | Router version | `clusterResources` collector | Router version for bundle tagging | API server CPU | k8s control plane | |
| Pod spec (`spec.containers[].env`) | Router deployment env vars: `APOLLO_GRAPH_REF`, `APOLLO_ROUTER_OFFICIAL_HELM_CHART` | `clusterResources` collector | Graph ref for bundle tagging, whether the router was deployed via Apollo's official Helm chart | API server CPU | k8s control plane | If a customer routes `APOLLO_GRAPH_REF` through a Secret via the chart's `extraEnvVars` only the reference is captured, not the value. |
| Separate `<release>-supergraph` ConfigMap | Schema (SDL) | `clusterResources` collector  | Full graph schema for diagnosis | API server CPU | k8s control plane | Absent for managed-federation customers. See [Where graph schema/SDL actually lands](#where-graph-schemasdl-actually-lands) below. |
| Container log stream | Runtime logs | `logs` collector | Recent router output, plus crash output from the previous container when one exists | Network bandwidth | Cluster network | Collected per pod, captures all containers in the pod (including proxy/mesh sidecars). **Previous-container logs are always collected**, written to `<name>-previous.log`. Configuration options: `logs.maxAge` and `logs.maxLines` are defined in `specs/deployment/v1/v1.md` → Chart values |
| Router metrics endpoint | Full Prometheus metrics snapshot | `http` collector | Complete operational metrics — request rates, error rates, latency, traffic shaping state | Network, router HTTP handler | Router network | Requires Prometheus endpoint enabled in `router.yaml`. See [Prometheus metrics prerequisites](#prometheus-metrics-prerequisites) below. |
| ConfigMap holding the rendered config | Sanitized `router.yaml` | `helm` + `configMap` collectors | Full router configuration — traffic shaping, timeouts, plugins, feature flags | API server CPU | k8s control plane | Captures config as written, not effective config (env-var overrides not included). See [`router.yaml` capture](#routeryaml-capture) below. |

### `router.yaml` capture

Two collectors run unconditionally to capture configuration. Whichever matches the customer's deployment populates, the other returns empty:

- **`helm` collector** (`collectValues: true`) — reads the Helm release values. Populates when the customer deployed via Helm. Captures the values layer, which may or may not equal the fully rendered config depending on chart structure. Most likely to succeed for other Helm-based deployments that don't follow the official chart's labeling convention.

- **`configMap` collector** — reads the ConfigMap holding the rendered `configuration.yaml` directly, targeted by label selector (`app.kubernetes.io/name=router`). Succeeds directly for the **official Apollo router Helm chart**.

**Each router release in a namespace gets its own file in the support bundle.** Label-based targeting matches every ConfigMap with `app.kubernetes.io/name=router`, so a namespace running more than one router release (one per graph, for example) has every release's config collected, each in its own separately-named file. See `specs/collection/meta_json.md` → Multiple router releases in one namespace.

### Schema collection

Schema only lands in the cluster at all when the customer sets `.Values.supergraphFile` on the router's Helm chart, not our support tool's chart. Customers on managed federation (GraphOS schema governance) never populate that value, so for them there is no `<release>-supergraph` ConfigMap and schema is simply absent from the bundle (see the "Absent for managed-federation customers" note on the `<release>-supergraph` ConfigMap row above).

When `supergraphFile` is set, the schema renders into a separate ConfigMap (`<release>-supergraph`), distinct from the main config ConfigMap. It carries the router chart's standard label, so it's swept up by the same `clusterResources` collection as everything else in the namespace, landing at `cluster-resources/configmaps/<namespace>.json` alongside the main config ConfigMap.

### Prometheus metrics prerequisites

The `http` collector targets the metrics endpoint at port `9090`. Three settings are load-bearing for this to return anything, from two different places:

**`router.yaml`** (via `.Values.router.configuration` in the Helm chart):

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the bind address. Binding to loopback means an external scrape can't reach it no matter what port the collector targets.

**Helm chart value** (not a `router.yaml` setting):

- `serviceMonitor.enabled: true` — the chart only adds a `metrics` port to the Service inside this flag. Without it, the Service has no `metrics` port at all, regardless of whether the exporter itself is on and reachable.

If any of the three is off or misconfigured, the collector returns empty and the rest of the bundle is unaffected.

### Namespace scoping is mandatory

`clusterResources`, `logs`, and `configMap` (when targeted by selector) all treat an empty namespace as "every namespace in the cluster". Therefore, namespace must be explicitly set on all three collectors.

### Memory and CPU information collected

What the base spec collects is sufficient to **detect, confirm, and characterize** a memory problem: is memory growing, how fast, how close to the limit, and did the kernel already kill the container. It does not answer *which code path is leaking* — that needs jemalloc heap profiling via the router's diagnostics plugin, out of scope for this base spec.

| Source | Signal | Collected via | What it tells you | Resource consumed | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| kubelet Summary API | `memory.workingSetBytes` | `nodeMetrics` collector | How much memory k8s counts against the limit — the OOM kill threshold | API server + kubelet CPU | k8s control plane → kubelet | Per node, per pod, per container. \[1\] \[2\] |
| Pod spec | Configured `resources.limits` / `requests` | `clusterResources` collector | What the usage numbers above should be compared against | API server CPU | k8s control plane | Already collected as part of the pod list |
| Kubernetes events (`OOMKilling`, evictions) | OOM kill **occurrences** | `clusterResources` collector | That OOM kills happened, when, and how often | API server CPU | k8s control plane | Per-occurrence record, retained as long as the cluster keeps events |
| Pod status `lastState.terminated.reason: OOMKilled`, `restartCount` | OOM kill **last state** | `clusterResources` collector | Whether the most recent restart was an OOM kill | API server CPU | k8s control plane | Survives event expiry |
| Node objects | Node `MemoryPressure` / `DiskPressure` conditions | `clusterResources` collector | Whether the node itself is under pressure, distinguishing a router problem from a neighbour's | API server CPU | k8s control plane | |
| Router Prometheus endpoint | `process_resident_memory_bytes` | `http` collector | Process-level RSS as the router sees it | Network, router HTTP handler | Router network | Requires the Prometheus exporter enabled and reachably bound. |
| Router Prometheus endpoint | `process_cpu_seconds_total` | `http` collector | CPU time consumed by the router process | Network, router HTTP handler | Router network | Same conditions as the row above |
| kubelet Summary API | `memory.rssBytes` | `nodeMetrics` collector | Physical RAM in use | API server + kubelet CPU | k8s control plane → kubelet | \[1\] \[2\] |
| kubelet Summary API | `memory.usageBytes`, `memory.availableBytes` | `nodeMetrics` collector | Usage, and headroom remaining against the limit | API server + kubelet CPU | k8s control plane → kubelet | \[1\] \[2\] |
| kubelet Summary API | `memory.pageFaults`, `memory.majorPageFaults` | `nodeMetrics` collector | Major faults indicate real paging pressure rather than growth alone | API server + kubelet CPU | k8s control plane → kubelet | \[1\] \[2\] |
| kubelet Summary API | `cpu.usageNanoCores`, `cpu.usageCoreNanoSeconds` | `nodeMetrics` collector | CPU consumed by the router container | API server + kubelet CPU | k8s control plane → kubelet | \[1\] \[2\] |
| kubelet Summary API | `cpu.psi`, `memory.psi` (pressure stall information) | `nodeMetrics` collector | Whether the container is *stalling* on CPU or memory | API server + kubelet CPU | k8s control plane → kubelet | Availability depends on Kubernetes version and the `KubeletPSI` feature gate. \[2\] |

**\[1\]** The Summary API reports per node, per pod, and per container. This assumes one router process per container.

#### [2] `nodeMetrics` is a fallback, not the preferred path

Enabling the Prometheus exporter (`telemetry.exporters.metrics.prometheus.enabled: true`) gets the same container-level usage-over-time signal without any cluster-wide RBAC grant. Customers should be pointed toward Prometheus first — `nodeMetrics` exists for the case where they haven't configured it yet, not as the default recommendation. It buys pre-OOM memory trajectory for those customers, at the cost of the `nodes`/`nodes/proxy`/`nodes/stats` grants — see `specs/deployment/v1/v1.md` → Permissions for what those grants are and what they cost.

## Service mesh and proxy environments

Some customers run a service mesh or proxy (Istio, Linkerd, Envoy) as a sidecar alongside the router. The proxy itself can be the root cause of what looks like a router problem. The `logs` collector captures every container in the pod, and the kubelet Summary API reports per-container figures, so a sidecar's own resource usage is visible alongside the router's.

A mesh enforcing strict mTLS can block the Prometheus scrape, causing the section to come back empty — the same symptom as the `listen`-address misconfiguration. The bundle alone can't tell you which.
