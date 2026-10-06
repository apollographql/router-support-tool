# Data Collected

The default collection spec is grounded in a TSH ticket analysis of the past year's support tickets and feedback from support and router engineers.

## What the base spec collects

These items are collected in the base spec. The table below is designed to be shared with customers so a platform team can review it, grant the access required for the collectors they want, and understand exactly what each one provides and what's lost if they decline it. Nothing is collected that isn't listed here.

Every bundle also carries a `meta.json` recording what the tool was configured to do, see `specs/collection/meta_json.md` for more details.

Collector names follow the conventions in `specs/collection/collector_naming.md`, which also lists the assigned name for every collector below.

References to "the official Apollo router Helm chart" are pinned to `v2.17.0`, and troubleshoot.sh is pinned to `v0.134.1` — see `specs/deployment/v1/v1.md` → troubleshoot.sh support-bundle version.

| Source | Signal | Collected via | What it tells you | Requires | Resource consumed | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| k8s API | Pod status, restart counts, resource limits | `clusterResources` collector | Whether pods are healthy, restart count, resource limits configured | None additional | API server CPU | k8s control plane | **Must be scoped with `namespaces: [<namespace>]`** — this collector defaults to every namespace in the cluster, and it collects ConfigMaps with their full `data`. |
| Container image tag | Router version | `clusterResources` collector | Router version | None additional | API server CPU | k8s control plane | |
| Pod spec (`spec.containers[].env`) | Router deployment env vars: `APOLLO_GRAPH_REF`, `APOLLO_ROUTER_OFFICIAL_HELM_CHART` | `clusterResources` collector | Graph ref, and whether the router was deployed via Apollo's official Helm chart | None additional | API server CPU | k8s control plane | If a customer routes `APOLLO_GRAPH_REF` through a Secret via the chart's `extraEnvVars` only the reference is captured, not the value. |
| Separate `<release>-supergraph` ConfigMap | Schema (SDL) | `clusterResources` collector, and (for the official Helm chart) the `configMap` collector too | Full graph schema for diagnosis | `.Values.supergraphFile` set on the router's Helm chart (see [Schema collection](#schema-collection) below) | API server CPU | k8s control plane | Absent for managed-federation customers. See [Where graph schema/SDL actually lands](#where-graph-schemasdl-actually-lands) below. |
| Container log stream | Runtime logs | `logs` collector | Recent router output, plus crash output from the previous container when one exists | None additional | Network bandwidth | Cluster network | Collected per pod, captures all containers in the pod (including proxy/mesh sidecars). **Previous-container logs are always collected**, written to `<name>-previous.log`. Configuration options: `logs.maxAge` and `logs.maxLines` are defined in `specs/deployment/v1/v1.md` → Chart values |
| Router metrics endpoint (per pod) | Full Prometheus metrics snapshot | `http` collector per pod under `mode: job`; `hostCollectors.run` script under `mode: local` | Complete operational metrics — request rates, error rates, latency, traffic shaping state | Prometheus exporter enabled and reachably bound (see [Prometheus metrics prerequisites](#prometheus-metrics-prerequisites) below) | Network, router HTTP handler | Router network | See [Per-pod metrics collection](#per-pod-metrics-collection) for how pods are resolved in each mode. |
| ConfigMap holding the rendered config | Sanitized `router.yaml` | `configMap` collector | Full router configuration — traffic shaping, timeouts, plugins, feature flags | A matching labeled ConfigMap present, or a customer-supplied `configMapName`/`selector` (see [`router.yaml` capture](#routeryaml-capture) below) | API server CPU | k8s control plane | Captures config as written, not effective config (env-var overrides not included). |

### `router.yaml` capture

The **`configMap` collector** is the primary mechanism that captures configuration. It reads the ConfigMap holding the rendered `configuration.yaml` directly, targeted by label selector (`app.kubernetes.io/name=router`), succeeding directly for the **official Apollo router Helm chart**, or by the customer-supplied `configMapName`/`selector` for raw-manifest and custom deployments (see `specs/deployment/v1/v1.md` → Chart values). A deployment that supplies neither, and whose config isn't discoverable under the standard label, gets an empty config section.

**Each matched ConfigMap gets its own file in the support bundle, named after that ConfigMap's own Kubernetes name.** Label-based targeting matches every ConfigMap with `app.kubernetes.io/name=router`, so a namespace running more than one router (one per graph, for example) has every one of their configs collected, each in its own separately-named file. This is a Kubernetes-resource-name convention, not a Helm release name — the two happen to coincide on the official Apollo router Helm chart, since it names the ConfigMap after the release, but a raw-manifest or custom deployment has no Helm release of the router at all. See `specs/collection/meta_json.md` → Multiple router releases in one namespace.

#### Known limitations
- A collected `router.yaml` is not verified to be the one the router loaded. Treat a populated `configmaps/` section as "a matching ConfigMap exists", not "confirmed active."

- We may not collect config at all: If `router.yaml` is mounted from a Secret, pulled by an init container, or mounted from a PVC, for example, it will not be collected.

### Schema collection

Schema only lands in the cluster at all when the customer sets `.Values.supergraphFile` on the router's Helm chart, not our support tool's chart. Customers on managed federation (GraphOS schema governance) never populate that value, so for them there is no `<release>-supergraph` ConfigMap and schema is simply absent from the bundle (see the "Absent for managed-federation customers" note on the `<release>-supergraph` ConfigMap row above).

When `supergraphFile` is set, the schema renders into a separate ConfigMap (`<release>-supergraph`), distinct from the main config ConfigMap. It carries the router chart's standard label, so it's swept up by the same `clusterResources` collection as everything else in the namespace, landing at `cluster-resources/configmaps/<namespace>.json` alongside the main config ConfigMap.

On the official Helm chart, that ConfigMap also carries the same `app.kubernetes.io/name=router` label the `configMap` collector matches on, so it's collected a second time there too — landing separately at `configmaps/<namespace>/<release>-supergraph.json`, alongside the main rendered config. The duplication is a side effect of label-based matching, not two distinct mechanisms worth telling apart: both copies carry identical content and both are covered by the same redactors (`router-subgraph-url-schema`'s `fileSelector` lists both paths explicitly).

### Prometheus metrics prerequisites

The `http` collector targets the metrics endpoint at port `9090` by default. The following settings are load-bearing for the collector to return anything, from two different places:

**`router.yaml`** (via `.Values.router.configuration` in the Helm chart):

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the bind address. Binding to loopback means an external scrape can't reach it no matter what port the collector targets.

If either is off or misconfigured, every metrics collector returns empty and the rest of the bundle is unaffected.

**Support bundle collection has to be able to reach pod IPs over the network.** `mode: job` satisfies this automatically, since the Job's pod is inside the cluster network. `mode: local` does not: the `support-bundle` binary runs on the invoking user's own machine, so the `router-metrics` host collector's own script bridges this itself, per pod, at collection time — see [Per-pod metrics collection](#per-pod-metrics-collection) below.

#### Per-pod metrics collection

Under `mode: job`, the spec emits one `http` collector per router pod matching the selector, named `router-metrics-<pod-name>`, each hitting that pod's IP directly at `metricsPort` (default `9090`). Pod IPs are resolved at Helm render time — a pod replaced between `helm install` and collection will produce a 404 for that slot, which is acceptable for the point-in-time collection this tool performs.

`selector` controls which pods are targeted, defaulting to `app.kubernetes.io/name=router`. Raw-manifest / custom deployments that set `selector` explicitly (see `specs/deployment/v1/v1.md` → Chart values common to both modes) use that same value here automatically. If no pods match at render time, no metrics collectors are emitted and the section is absent from the bundle.

Under `mode: local`, the spec emits a `hostCollectors.run` collector named `router-metrics` — a troubleshoot.sh collector type that just executes whatever script the spec hands it. The script is ours, shipped in `router-diagnostics-chart` and templated into the spec ConfigMap at `helm install` time using the `selector`/`metricsPort` values given there. It resolves all pods matching the selector, sequentially port-forwards each pod's metrics port to `localhost:metricsPort`, scrapes `/metrics` to stdout, then kills the forward before moving to the next pod. Each pod's scrape is written to its own `<pod-name>.txt` file via the collector's `outputDir: router-metrics`, mirroring the per-pod isolation that job mode gets from its individual `http` collectors. This bridging runs as part of `support-bundle` itself when `collect.sh` invokes it — `collect.sh` takes no flags of its own for it (see `specs/deployment/v1/v1.md` → `mode: local`).

**This lands at a different bundle path than a `mode: job` `http` collector's `outputDir` does.** troubleshoot.sh nests a host run collector's `outputDir` under `host-collectors/run-host/<collectorName>/` — this collector's `collectorName` is `router-metrics` and its `outputDir` is `pods` so files are at `host-collectors/run-host/router-metrics/pods/<pod-name>.txt`. See `specs/collection/output.md` → Bundle layout differs by mode for the full contrast with `mode: job`'s layout. This path is pinned to the troubleshoot.sh version this chart bundles (`specs/deployment/v1/v1.md` → troubleshoot.sh support-bundle version).

### Namespace scoping is mandatory

`clusterResources`, `logs`, and `configMap` (when targeted by selector) all treat an empty namespace as "every namespace in the cluster". Therefore, namespace must be explicitly set on all three collectors.

### Memory and CPU information collected

What the base spec collects is sufficient to **detect, confirm, and characterize** a memory problem: is memory growing, how fast, how close to the limit, and did the kernel already kill the container. The router also emits jemalloc-level aggregate gauges (`apollo.router.jemalloc.active`, `.allocated`, `.resident`, `.retained`, etc.) on the same Prometheus endpoint the `http` collector already scrapes, which can help distinguish real heap growth from jemalloc fragmentation. What none of this answers is *which code path is leaking* — that needs jemalloc heap profiling via the router's diagnostics plugin, out of scope for this base spec.

**All rows below are attempted unconditionally on every run.** There is no branching based on what else is configured — `clusterResources` and `nodeMetrics` both run whether or not Prometheus is enabled, and `http` runs whether or not `nodeMetrics` RBAC was granted. The "Requires" column states what has to be true for that specific row to come back populated instead of empty; it is not a condition on any other row in this table.

| Signal | Source | Collected via | What it tells you | Requires | Resource consumed | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| `memory.workingSetBytes` | kubelet Summary API | `nodeMetrics` collector | How much memory k8s counts against the limit — the OOM kill threshold | `nodes`/`nodes/proxy`/`nodes/stats` RBAC grant \[2\] | API server + kubelet CPU | k8s control plane → kubelet | Per node, per pod, per container. \[1\] |
| Configured `resources.limits` / `requests` | Pod spec | `clusterResources` collector | What the usage numbers above should be compared against | None additional | API server CPU | k8s control plane | Same pod collection as the "Pod status" row above |
| OOM kill **occurrences** | Kubernetes events (`OOMKilling`, evictions) | `clusterResources` collector | That OOM kills happened, when, and how often | None additional | API server CPU | k8s control plane | Per-occurrence record, retained as long as the cluster keeps events |
| OOM kill **last state** | Pod status `lastState.terminated.reason: OOMKilled`, `restartCount` | `clusterResources` collector | Whether the most recent restart was an OOM kill | None additional | API server CPU | k8s control plane | Survives event expiry |
| Node `MemoryPressure` / `DiskPressure` conditions | Node objects | `clusterResources` collector | Whether the node itself is under pressure, distinguishing a router problem from a neighbour's | None additional | API server CPU | k8s control plane | |
| `process_resident_memory_bytes` | Router Prometheus endpoint | `http` collector | Process-level RSS as the router sees it | Prometheus exporter enabled and reachably bound (see [Prometheus metrics prerequisites](#prometheus-metrics-prerequisites)) | Network, router HTTP handler | Router network | |
| `process_cpu_seconds_total` | Router Prometheus endpoint | `http` collector | CPU time consumed by the router process | Same as the row above | Network, router HTTP handler | Router network | |
| `memory.rssBytes` | kubelet Summary API | `nodeMetrics` collector | Physical RAM in use | `nodes`/`nodes/proxy`/`nodes/stats` RBAC grant \[2\] | API server + kubelet CPU | k8s control plane → kubelet | \[1\] |
| `memory.usageBytes`, `memory.availableBytes` | kubelet Summary API | `nodeMetrics` collector | Usage, and headroom remaining against the limit | `nodes`/`nodes/proxy`/`nodes/stats` RBAC grant \[2\] | API server + kubelet CPU | k8s control plane → kubelet | \[1\] |
| `memory.pageFaults`, `memory.majorPageFaults` | kubelet Summary API | `nodeMetrics` collector | Major faults indicate real paging pressure rather than growth alone | `nodes`/`nodes/proxy`/`nodes/stats` RBAC grant \[2\] | API server + kubelet CPU | k8s control plane → kubelet | \[1\] |
| `cpu.usageNanoCores`, `cpu.usageCoreNanoSeconds` | kubelet Summary API | `nodeMetrics` collector | CPU consumed by the router container | `nodes`/`nodes/proxy`/`nodes/stats` RBAC grant \[2\] | API server + kubelet CPU | k8s control plane → kubelet | \[1\] |
| `cpu.psi`, `memory.psi` (pressure stall information) | kubelet Summary API | `nodeMetrics` collector | Whether the container is *stalling* on CPU or memory | `nodes`/`nodes/proxy`/`nodes/stats` RBAC grant \[2\], plus the `KubeletPSI` feature gate on the cluster | API server + kubelet CPU | k8s control plane → kubelet | |

**\[1\]** The Summary API reports per node, per pod, and per container. This assumes one router process per container.

**\[2\]** `nodeMetrics` is a fallback, not the preferred path. Enabling the Prometheus exporter (`telemetry.exporters.metrics.prometheus.enabled: true`) gets the same container-level usage-over-time signal without any cluster-wide RBAC grant. Customers should be pointed toward Prometheus first — `nodeMetrics` exists for the case where they haven't configured it yet, not as the default recommendation. It buys pre-OOM memory trajectory for those customers, at the cost of the `nodes`/`nodes/proxy`/`nodes/stats` grants — see `specs/deployment/v1/v1.md` → Permissions for what those grants are and what they cost.

## Service mesh and proxy environments

Some customers run a service mesh or proxy (Istio, Linkerd, Envoy) as a sidecar alongside the router. The proxy itself can be the root cause of what looks like a router problem. The `logs` collector captures every container in the pod, and the kubelet Summary API reports per-container figures, so a sidecar's own resource usage is visible alongside the router's.

A mesh enforcing strict mTLS can block the Prometheus scrape, causing the section to come back empty — the same symptom as the `listen`-address misconfiguration. The bundle alone can't tell you which.
