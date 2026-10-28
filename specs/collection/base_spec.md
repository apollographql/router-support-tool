# Data Collected

The default collection spec is grounded in a TSH ticket analysis of the past year's support tickets and feedback from support and router engineers.

## What the base spec collects

These items are collected in the base spec. The table below is designed to be shared with customers so a platform team can review it, grant the access required for the collectors they want, and understand exactly what each one provides and what's lost if they decline it. Nothing is collected that isn't listed here.

Every bundle also carries a `meta.json` recording what the tool was configured to do, see `specs/collection/meta_json.md` for more details.

Collector names follow the conventions in `specs/collection/collector_naming.md`, which also lists the assigned name for every collector below.

References to "the official Apollo router Helm chart" are pinned to `v2.17.0`, and troubleshoot.sh is pinned to `v0.134.1` — see `specs/deployment/on-demand-collection.md` → troubleshoot.sh support-bundle version.

| Source | Signal | Collected via | What it tells you | Requires | Resource consumed | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| k8s API | Pod status, restart counts, resource limits | `clusterResources` collector | Whether pods are healthy, restart count, resource limits configured | None additional | API server CPU | k8s control plane | **Must be scoped with `namespaces: [<namespace>]`** — this collector defaults to every namespace in the cluster, and it collects ConfigMaps with their full `data`. |
| Container image tag | Router version | `clusterResources` collector | Router version | None additional | API server CPU | k8s control plane | |
| Pod spec (`spec.containers[].env`) | Router deployment env vars: `APOLLO_GRAPH_REF`, `APOLLO_ROUTER_OFFICIAL_HELM_CHART` | `clusterResources` collector | Graph ref, and whether the router was deployed via Apollo's official Helm chart | None additional | API server CPU | k8s control plane | If a customer routes `APOLLO_GRAPH_REF` through a Secret via the chart's `extraEnvVars` only the reference is captured, not the value. |
| Separate `<release>-supergraph` ConfigMap | Schema (SDL) | `clusterResources` collector, and (for the official Helm chart) the `configMap` collector too | Full graph schema for diagnosis | `.Values.supergraphFile` set on the router's Helm chart (see [Schema collection](#schema-collection) below) | API server CPU | k8s control plane | Absent for managed-federation customers. See [Where graph schema/SDL actually lands](#where-graph-schemasdl-actually-lands) below. |
| Container log stream | Runtime logs | `logs` collector | Recent router output, plus crash output from the previous container when one exists | None additional | Network bandwidth | Cluster network | Collected per pod, captures all containers in the pod (including proxy/mesh sidecars). **Previous-container logs are always collected**, written to `<name>-previous.log`. Configuration options: `logs.maxAge` and `logs.maxLines` are defined in `specs/deployment/on-demand-collection.md` → Chart values |
| Router metrics endpoint (per pod) | Full Prometheus metrics snapshot | `run` collector (`router-metrics`) | Complete operational metrics — request rates, error rates, latency, traffic shaping state | Prometheus exporter enabled and reachably bound (see [Prometheus metrics prerequisites](#prometheus-metrics-prerequisites) below) | Network, router HTTP handler | Router network | Pods are resolved when collection runs, not when the chart renders. See [Per-pod metrics collection](#per-pod-metrics-collection). |
| ConfigMap holding the rendered config | Sanitized `router.yaml` | `configMap` collector | Full router configuration — traffic shaping, timeouts, plugins, feature flags | A matching labeled ConfigMap present, or a customer-supplied `configMapName`/`selector` (see [`router.yaml` capture](#routeryaml-capture) below) | API server CPU | k8s control plane | Captures config as written, not effective config (env-var overrides not included). |

### `router.yaml` capture

The **`configMap` collector** is the primary mechanism that captures configuration. It reads the ConfigMap holding the rendered `configuration.yaml` directly, targeted by label selector (`app.kubernetes.io/name=router`), succeeding directly for the **official Apollo router Helm chart**, or by the customer-supplied `configMapName`/`selector` for raw-manifest and custom deployments (see `specs/deployment/on-demand-collection.md` → Chart values). A deployment that supplies neither, and whose config isn't discoverable under the standard label, gets an empty config section.

**Each matched ConfigMap gets its own file in the support bundle, named after that ConfigMap's own Kubernetes name.** Label-based targeting matches every ConfigMap with `app.kubernetes.io/name=router`, so a namespace running more than one router (one per graph, for example) has every one of their configs collected, each in its own separately-named file. This is a Kubernetes-resource-name convention, not a Helm release name — the two happen to coincide on the official Apollo router Helm chart, since it names the ConfigMap after the release, but a raw-manifest or custom deployment has no Helm release of the router at all. See `specs/collection/meta_json.md` → Multiple router releases in one namespace.

#### Known limitations
- A collected `router.yaml` is not verified to be the one the router loaded. Treat a populated `configmaps/` section as "a matching ConfigMap exists", not "confirmed active."

- We may not collect config at all: If `router.yaml` is mounted from a Secret, pulled by an init container, or mounted from a PVC, for example, it will not be collected.

### Schema collection

Schema only lands in the cluster at all when the customer sets `.Values.supergraphFile` on the router's Helm chart, not our support tool's chart. Customers on managed federation (GraphOS schema governance) never populate that value, so for them there is no `<release>-supergraph` ConfigMap and schema is simply absent from the bundle (see the "Absent for managed-federation customers" note on the `<release>-supergraph` ConfigMap row above).

When `supergraphFile` is set, the schema renders into a separate ConfigMap (`<release>-supergraph`), distinct from the main config ConfigMap. It carries the router chart's standard label, so it's swept up by the same `clusterResources` collection as everything else in the namespace, landing at `cluster-resources/configmaps/<namespace>.json` alongside the main config ConfigMap.

On the official Helm chart, that ConfigMap also carries the same `app.kubernetes.io/name=router` label the `configMap` collector matches on, so it's collected a second time there too — landing separately at `configmaps/<namespace>/<release>-supergraph.json`, alongside the main rendered config. The duplication is a side effect of label-based matching, not two distinct mechanisms worth telling apart: both copies carry identical content and both are covered by the same redactors (`router-subgraph-url-schema`'s `fileSelector` lists both paths explicitly).

### Prometheus metrics prerequisites

The `router-metrics` collector targets each pod's metrics endpoint at port `9090` by default (`metricsPort`). The following settings are load-bearing for the collector to return anything, from two different places:

**`router.yaml`** (via `.Values.router.configuration` in the Helm chart):

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the bind address. Binding to loopback means an external scrape can't reach it no matter what port the collector targets.

If either is off or misconfigured, `router-metrics` collects no per-pod files and writes an explanation into the bundle instead (see [Per-pod metrics collection](#per-pod-metrics-collection)); the rest of the bundle is unaffected.

**Support bundle collection has to be able to reach each pod's metrics port over the network.** `mode: job` satisfies this automatically, since the Job's pod is inside the cluster network and reaches pod IPs directly. `mode: local` does not: the `support-bundle` binary runs on the invoking user's own machine, so the `router-metrics` script bridges this itself, per pod, at collection time — see [Per-pod metrics collection](#per-pod-metrics-collection) below.

#### Per-pod metrics collection

Both modes collect metrics with the same collector: a `hostCollectors.run` collector named `router-metrics`, a troubleshoot.sh collector type that just executes whatever script the spec hands it. The script is ours, shipped in `router-diagnostics-chart` and templated into the spec ConfigMap using the `namespace`/`selector`/`metricsPort` values given at install. troubleshoot.sh runs it wherever `support-bundle` runs: on the invoking user's own machine under `mode: local`, inside the Job's pod under `mode: job`.

**Pods are resolved when collection runs, never when the chart renders.** Each run, the script lists the pods matching `selector` in `namespace` with `kubectl get pods`, then scrapes `/metrics` from each matched pod. The rendered spec contains no pod names or IPs. So it renders the same whether the chart was installed against a live cluster (`helm install`) or rendered offline (`helm template`, which is all ArgoCD and similar GitOps tools run), and a pod replaced since install is scraped under its new name and IP.

How the script reaches each pod is the only part that differs by mode:

- **`mode: job`**: the Job's pod is inside the cluster network, so the script requests `http://<pod-ip>:<metricsPort>/metrics` directly, using the pod IP from the same `kubectl get pods` listing. No port-forward is involved. Pods are scraped in batches of ten at a time, each request capped at 30 seconds, so a fleet of unresponsive pods costs about 30 seconds per ten pods rather than 30 seconds per pod. A matched pod that has no IP yet (for example one still `Pending`) is not scraped.
- **`mode: local`**: pod IPs are not reachable from the user's machine, so the script port-forwards each pod's metrics port to `localhost:<metricsPort>`, scrapes, then kills the forward before moving to the next pod. This bridging runs as part of `support-bundle` itself when `collect.sh` invokes it — `collect.sh` takes no flags of its own for it (see `specs/deployment/on-demand-collection.md` → `mode: local`).

`selector` defaults to `app.kubernetes.io/name=router`. Raw-manifest / custom deployments that set `selector` explicitly (see `specs/deployment/on-demand-collection.md` → Chart values common to both modes) use that same value here automatically. It is the same value that targets the `logs` and `configMap` collectors; this collector reads it and changes nothing about how they use it.

**Each pod's scrape is written to its own `<pod-name>.txt` file.** troubleshoot.sh nests a host run collector's `outputDir` under `host-collectors/run-host/<collectorName>/`. This collector's `collectorName` is `router-metrics` and its `outputDir` is `pods`, so files land at `host-collectors/run-host/router-metrics/pods/<pod-name>.txt`. See `specs/collection/output.md` → `router-metrics` layout. This path is pinned to the troubleshoot.sh version this chart bundles (`specs/deployment/on-demand-collection.md` → troubleshoot.sh support-bundle version).

**Missing metrics always come with a named reason in the bundle.** The script writes one line to its output, rather than leaving the section silently empty, in each of these cases:

| Case | Line written | What it points to |
| --- | --- | --- |
| `kubectl` can't list pods in `namespace` | `metrics not collected: could not list pods matching selector <selector> in namespace <namespace>` | Access, not the selector: missing `get`/`list` on pods (the Job's Role under `mode: job`, the invoking user's credentials under `mode: local`), or an API server the script can't reach. `kubectl`'s own error is in `host-collectors/run-host/router-metrics-stderr.txt`. |
| No pod matches `selector` in `namespace` | `metrics not collected: no pods matched selector <selector> in namespace <namespace>` | A wrong `selector` or `namespace`, or a router whose pod label isn't the default — for example, an official-chart install with `router.nameOverride` set or under an aliased release, where `app.kubernetes.io/name` is no longer `router`. Fix by setting `selector`. |
| A matched pod doesn't respond on `metricsPort` | `metrics not collected for pod <pod-name>: no response on port <metricsPort>`, followed under `mode: local` by `kubectl port-forward`'s own error when it printed one | That pod's exporter specifically: down, restarting, or blocked by a mesh. Under `mode: local`, a port-forward error in the line, such as a `forbidden` message naming `pods/portforward`, means the forward itself failed, for example for missing `create` on `pods/portforward` or a local port already in use. Other pods' files are unaffected. |
| A matched pod has no IP yet (`mode: job` only) | `metrics not collected for pod <pod-name>: pod has no IP yet` | The pod hasn't been assigned an IP, usually because it is still `Pending` or starting, so there is nothing to scrape. Not an exporter problem. Collect again once the pod is `Running`. Other pods' files are unaffected. Under `mode: local` the script port-forwards by pod name and never uses the IP, so a `Pending` pod there gets the "no response" line with the port-forward's error instead. |
| Pods were scraped, but none responded | `metrics not collected: no pod responded on port <metricsPort> — prometheus may not be enabled` | The exporter prerequisites above, `metricsPort`, or a mesh enforcing strict mTLS. Each pod's own line above says whether its port-forward failed (see [Service mesh and proxy environments](#service-mesh-and-proxy-environments)). Not written when no pod had an IP to scrape, because then no exporter was asked and the lines above already say why. |

**What the script needs to run:**

- `kubectl` and `curl` on the machine running it. Under `mode: local` that's the user's own machine (the collect script already requires `kubectl`). Under `mode: job` the Job image bundles both (`specs/deployment/on-demand-collection.md` → The Job image).
- `get`/`list` on pods in `namespace`. Under `mode: job` the Job's namespace-scoped Role already grants this. Under `mode: local` it uses the invoking user's own credentials, plus `create` on `pods/portforward`.
- `ignoreParentEnvs: true` so the script doesn't inherit, and troubleshoot.sh's diagnostic sidecar doesn't record, the environment it was launched from (`specs/collection/data_sanitization/host_collector_diagnostics.md`). Under `mode: job` that environment includes object-storage credentials injected into the Job container. As a result, the script doesn't inherit the `KUBERNETES_SERVICE_HOST`/`KUBERNETES_SERVICE_PORT` variables `kubectl` normally relies on to find the API server from inside a pod. Under `mode: job`, the script must therefore point `kubectl` at the API server explicitly, using the in-cluster address and the Job's mounted ServiceAccount token and CA, rather than relying on that autodetection.

### Namespace scoping is mandatory

`clusterResources`, `logs`, and `configMap` (when targeted by selector) all treat an empty namespace as "every namespace in the cluster". Therefore, namespace must be explicitly set on all three collectors.

### Memory and CPU information collected

What the base spec collects is sufficient to **detect, confirm, and characterize** a memory problem: is memory growing, how fast, how close to the limit, and did the kernel already kill the container. The router also emits jemalloc-level aggregate gauges (`apollo.router.jemalloc.active`, `.allocated`, `.resident`, `.retained`, etc.) on the same Prometheus endpoint `router-metrics` already scrapes, which can help distinguish real heap growth from jemalloc fragmentation. What none of this answers is *which code path is leaking* — that needs jemalloc heap profiling via the router's diagnostics plugin, out of scope for this base spec.

**All rows below are attempted unconditionally on every run.** There is no branching based on what else is configured — `clusterResources` and the kubelet stats collector (`router-resource-usage`) both run whether or not Prometheus is enabled, and `router-metrics` runs whether or not the kubelet stats grants were given. The "Requires" column states what has to be true for that specific row to come back populated instead of empty; it is not a condition on any other row in this table.

| Signal | Source | Collected via | What it tells you | Requires | Resource consumed | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| `memory.workingSetBytes` | kubelet Summary API | `router-resource-usage` collector \[2\] | How much memory k8s counts against the limit — the OOM kill threshold | `nodes/stats` RBAC grant (`mode: job`), see \[2\] | kubelet CPU (plus API server CPU in `mode: local`) | Cluster network → kubelet (`mode: job`); k8s control plane → kubelet (`mode: local`) | Per node, per pod, per container. \[1\] |
| Configured `resources.limits` / `requests` | Pod spec | `clusterResources` collector | What the usage numbers above should be compared against | None additional | API server CPU | k8s control plane | Same pod collection as the "Pod status" row above |
| OOM kill **occurrences** | Kubernetes events (`OOMKilling`, evictions) | `clusterResources` collector | That OOM kills happened, when, and how often | None additional | API server CPU | k8s control plane | Per-occurrence record, retained as long as the cluster keeps events |
| OOM kill **last state** | Pod status `lastState.terminated.reason: OOMKilled`, `restartCount` | `clusterResources` collector | Whether the most recent restart was an OOM kill | None additional | API server CPU | k8s control plane | Survives event expiry |
| Node `MemoryPressure` / `DiskPressure` conditions | Node objects | `clusterResources` collector | Whether the node itself is under pressure, distinguishing a router problem from a neighbour's | `nodes` (list) RBAC grant, cluster-scoped \[2\] | API server CPU | k8s control plane | |
| `apollo_router_jemalloc_allocated`, `_active`, `_resident`, `_mapped`, `_metadata`, `_retained` | Router Prometheus endpoint | `run` collector (`router-metrics`) | The router's own allocator view of memory: separates real heap growth (`allocated`) from allocator retention (`resident`, `retained`) | Prometheus exporter enabled and reachably bound (see [Prometheus metrics prerequisites](#prometheus-metrics-prerequisites)), on router v2.16.3 or later built with jemalloc, as the official release builds are | Network, router HTTP handler | Router network | The router does not serve process-level RSS or CPU metrics; use the `memory.rssBytes` and `cpu.*` rows below |
| `memory.rssBytes` | kubelet Summary API | `router-resource-usage` collector \[2\] | Physical RAM in use | `nodes/stats` RBAC grant (`mode: job`), see \[2\] | kubelet CPU (plus API server CPU in `mode: local`) | Cluster network → kubelet (`mode: job`); k8s control plane → kubelet (`mode: local`) | \[1\] |
| `memory.usageBytes`, `memory.availableBytes` | kubelet Summary API | `router-resource-usage` collector \[2\] | Usage, and headroom remaining against the limit | `nodes/stats` RBAC grant (`mode: job`), see \[2\] | kubelet CPU (plus API server CPU in `mode: local`) | Cluster network → kubelet (`mode: job`); k8s control plane → kubelet (`mode: local`) | \[1\] |
| `memory.pageFaults`, `memory.majorPageFaults` | kubelet Summary API | `router-resource-usage` collector \[2\] | Major faults indicate real paging pressure rather than growth alone | `nodes/stats` RBAC grant (`mode: job`), see \[2\] | kubelet CPU (plus API server CPU in `mode: local`) | Cluster network → kubelet (`mode: job`); k8s control plane → kubelet (`mode: local`) | \[1\] |
| `cpu.usageNanoCores`, `cpu.usageCoreNanoSeconds` | kubelet Summary API | `router-resource-usage` collector \[2\] | CPU consumed by the router container | `nodes/stats` RBAC grant (`mode: job`), see \[2\] | kubelet CPU (plus API server CPU in `mode: local`) | Cluster network → kubelet (`mode: job`); k8s control plane → kubelet (`mode: local`) | \[1\] |
| `containers[].usage.cpu`, `containers[].usage.memory` (working set) | metrics API (`metrics.k8s.io`) | `router-resource-usage` collector \[2\], fallback, `mode: job` only | CPU rate and working-set memory when the kubelet can't be read | namespaced `get`/`list` on `pods` in `metrics.k8s.io`, and metrics-server installed | metrics-server and API server CPU | Cluster network → API server | Only the router pods on nodes whose kubelet read failed or was declined. Less detail than the kubelet: no RSS, page faults or pressure stall data. |
| `cpu.psi`, `memory.psi` (pressure stall information) | kubelet Summary API | `router-resource-usage` collector \[2\] | Whether the container is *stalling* on CPU or memory | `nodes/stats` RBAC grant (`mode: job`), see \[2\], plus the `KubeletPSI` feature gate on the cluster | kubelet CPU (plus API server CPU in `mode: local`) | Cluster network → kubelet (`mode: job`); k8s control plane → kubelet (`mode: local`) | |
| `container_cpu_cfs_throttled_periods_total`, `container_cpu_cfs_throttled_seconds_total` | kubelet cAdvisor endpoint | `router-resource-usage` collector \[2\], `mode: job` only | Whether the container is being throttled against its CPU limit, and for how long | `nodes/metrics` RBAC grant and `job.collectCadvisorMetrics: true` | kubelet CPU | Cluster network → kubelet | Router pods' series only. Opt-in. |
| `container_oom_events_total`, `container_memory_failcnt` | kubelet cAdvisor endpoint | `router-resource-usage` collector \[2\], `mode: job` only | How often the kernel recorded the container hitting its memory limit or an OOM event, counted since the container started | `nodes/metrics` RBAC grant and `job.collectCadvisorMetrics: true` | kubelet CPU | Cluster network → kubelet | Router pods' series only. Opt-in. |

**\[1\]** The Summary API reports per node, per pod, and per container. This assumes one router process per container.

**\[2\]** Container memory and CPU come from the kubelet, never from inside the router container. Under `mode: job`, a script collector named `router-resource-usage` reads the kubelet's `/stats/summary` directly from the Job's pod and needs one cluster-scoped grant, `nodes/stats` (get), falling back per node to the metrics API (working set and CPU only) when the kubelet can't be used; `job.nodeStatsSource: apiServer` uses `nodeMetrics` instead, as `mode: local` does. Node pressure conditions (`clusterResources`) additionally need `nodes` (list). Under `mode: local`, the `nodeMetrics` collector reads the same data through the API server's proxy, which needs `nodes`, `nodes/proxy` and `nodes/stats` on the invoking user's own credentials. The router's Prometheus exporter needs none of this but serves only jemalloc memory gauges: no CPU, and no container RSS or working set. See [Kubelet stats collection](#kubelet-stats-collection-mode-job) and `specs/deployment/on-demand-collection.md` → Kubelet stats RBAC.

#### Kubelet stats collection (`mode: job`)

Container memory and CPU always come from the kubelet, never from inside the router container. How the kubelet is reached depends on the mode:

- **`mode: job`**: a `hostCollectors.run` collector named `router-resource-usage` reads the kubelet directly. Like `router-metrics`, it is a script shipped in `router-diagnostics-chart` and templated into the spec ConfigMap, and troubleshoot.sh runs it inside the Job's pod. Because it calls the kubelet itself, the kubelet's own authorization applies and the broad `nodes/proxy` grant is not needed (`specs/deployment/on-demand-collection.md` → Kubelet stats RBAC). `job.nodeStatsSource: apiServer` swaps this for the `nodeMetrics` collector; see [Sources and fallback](#sources-and-fallback).
- **`mode: local`**: unchanged. The `nodeMetrics` collector reads the Summary API through the API server's proxy using the invoking user's own credentials, which needs `nodes`, `nodes/proxy` and `nodes/stats`. A user's machine generally cannot reach node IPs, so the direct route is not available there.

**Nodes are resolved when collection runs, never when the chart renders**, for the same reason as `router-metrics`: a renderer that only runs `helm template`, such as ArgoCD, must produce the same spec. Each run lists the pods matching `selector` in `namespace` with `kubectl get pods` (the same `selector` `router-metrics` uses), takes each pod's `status.hostIP`, and asks each distinct node's kubelet once, in batches of ten at a time with each request capped at 30 seconds. For each node:

1. `GET https://<hostIP>:10250/stats/summary`, with the Job's ServiceAccount token as a bearer token.
2. The script keeps the node-level figures and only the entries for the matched pods, then writes that. Other workloads on the node never reach the bundle. `nodeMetrics` does not guarantee this: it writes every pod on the node.
3. When `job.collectCadvisorMetrics` is `true`, it also requests `https://<hostIP>:10250/metrics/cadvisor` and keeps only the series labelled with a matched pod, plus their `# HELP` and `# TYPE` lines.

#### Sources and fallback

`router-resource-usage` has two sources, tried in this order for each node:

1. **The kubelet**, as above. Full detail: working set, RSS, usage, page faults, CPU rate and, where the cluster enables it, pressure stall data.
2. **The metrics API (`metrics.k8s.io`)**, used for a node's pods when the kubelet read for that node failed with *could not reach* or *refused*, or when the kubelet read was declined at install. A pod with no node yet is not retried: the metrics API has nothing for it either. The script runs `kubectl get pods.metrics.k8s.io -n <namespace> -l <selector> -o json` once, keeps the entries for the pods on the affected nodes, and writes them to that node's `metrics-api.json`. It goes through the API server, so it does not depend on the Job's pod reaching the node, and it needs only a namespaced grant. It returns working-set memory and a CPU rate per container, with a timestamp and window, and nothing else.

Each node therefore ends with `stats-summary.json` (kubelet), `metrics-api.json` (fallback), or a named reason and neither. A node never has both. Which source a node used is visible from which file exists and from the line the script wrote.

**`job.nodeStatsSource: apiServer` replaces this collector** with `nodeMetrics`, which reads the Summary API through the API server's proxy, as `mode: local` does. It has no metrics API fallback and writes every pod on the node to the engine-fixed `node-metrics/<node-name>.json`. It exists for clusters where the Job's pod can't reach the kubelet and metrics-server isn't installed, and for customers who accept the `nodes/proxy` grant; see `specs/deployment/on-demand-collection.md` → Kubelet stats RBAC.

**The kubelet's TLS certificate is not verified** (`curl -k`). Its serving certificate is commonly self-signed, or issued by a CA other than the one mounted in the pod, so verifying would fail on most clusters. The accepted risk is that the token is sent to an endpoint whose identity isn't checked. The token is the Job pod's bound ServiceAccount token, which stops being valid when the pod is deleted, and the only cluster-scoped access it carries is read on `nodes/stats` (and `nodes/metrics` when opted in) and `nodes`.

**Every request goes to the kubelet, none to the router container**, so collection draws nothing from the router's cgroup allocation, and the signal is gathered externally as the base spec requires (`specs/architecture.md` → base spec). The script makes one summary request per node. The cAdvisor read returns far more data per node and is opt-in for that reason.

Files land under `host-collectors/run-host/router-resource-usage/nodes/<node-name>/`: `stats-summary.json`, and `cadvisor.txt` when opted in. See `specs/collection/output.md` → `router-resource-usage` layout. Under `mode: job` there is no `node-metrics/` directory.

**Missing data always comes with a named reason in the bundle.** The script writes one line to its output in each of these cases, in the same way as `router-metrics`:

| Case | Line written | What it points to |
| --- | --- | --- |
| `kubectl` can't list pods in `namespace` | `kubelet stats not collected: could not list pods matching selector <selector> in namespace <namespace>` | Access to pods, not the kubelet: missing `get`/`list` on pods in the Job's Role, or an API server the script can't reach. `kubectl`'s own error is in `host-collectors/run-host/router-resource-usage-stderr.txt`. |
| No pod matches `selector` in `namespace` | `kubelet stats not collected: no pods matched selector <selector> in namespace <namespace>` | A wrong `selector` or `namespace`, as for `router-metrics`. |
| Declined at install | `kubelet stats not collected: declined at install (job.collectNodeMetrics is false)` | Rendered into the script when the chart is installed with `job.collectNodeMetrics: false`; no request is made to the kubelet, and the script tries the metrics API instead. A render-time fact, like `meta.json`, not a failure. |
| A matched pod has no node yet | `kubelet stats not collected for pod <pod-name>: pod has no node yet` | The pod isn't scheduled (usually `Pending`), so `status.hostIP` is unset. Not a kubelet problem. Other pods are unaffected. |
| The kubelet can't be reached | `kubelet stats not collected for node <node-name>: could not reach the kubelet at <hostIP>:10250` | The network path from the Job's pod to the node: a NetworkPolicy blocking egress, a cloud firewall, or a non-default kubelet port. Not RBAC. The script then tries the metrics API for that node's pods. |
| The kubelet refused the request | `kubelet stats not collected for node <node-name>: kubelet returned HTTP <code>` (`kubelet cadvisor metrics not collected …` for the cAdvisor read) | `401`/`403`: the Job's ServiceAccount lacks `nodes/stats` (or `nodes/metrics` for the cAdvisor read), usually because the ClusterRole wasn't created or was edited. The script then tries the metrics API for that node's pods. |
| A matched pod is missing from its node's stats | `kubelet stats not collected for pod <pod-name>: not in node <node-name>'s stats` | The pod was replaced or deleted between listing and the kubelet read. Other pods are unaffected. |
| The metrics API doesn't exist | `metrics API not available: metrics.k8s.io not found` | metrics-server isn't installed (`404`). Only reached after a kubelet failure or decline, so the node has no memory or CPU data. |
| The metrics API is unhealthy | `metrics API not available: service unavailable` | The `metrics.k8s.io` APIService exists but its backend isn't answering (`503`): metrics-server is crashing or not ready. |
| The metrics API refused the request | `metrics API not available: forbidden` | The Job's Role lacks `get`/`list` on `pods` in `metrics.k8s.io`, usually because the Role was edited. |
| The metrics API has no entry for a pod | `metrics API has no entry for pod <pod-name>` | metrics-server hasn't scraped the pod yet, usually because it started in the last minute or so. Other pods are unaffected. |

**What the script needs to run:**

- `kubectl`, `curl` and `python3` in the Job image (`specs/deployment/on-demand-collection.md` → The Job image). `python3` does the filtering to the matched pods.
- `get`/`list` on pods in `namespace`, from the Job's namespace-scoped Role, the cluster-scoped grants in Kubelet stats RBAC, and, for the fallback, `get`/`list` on `pods` in `metrics.k8s.io` from the same Role.
- A network path from the Job's pod to each router node's IP on the kubelet's default secure port, `10250`. A kubelet on another port is not supported. Without this path the script falls back to the metrics API. An IPv6 host IP must be bracketed in the URL.
- `ignoreParentEnvs: true`, and `kubectl` pointed at the API server explicitly, for the reasons given for `router-metrics`. The ServiceAccount token is read from the Job's mounted token file at run time.
- The token must never appear in the script's output, its stderr, or the diagnostic sidecar: no `curl -v`, no `set -x`. The sidecar is redacted wholesale (`specs/collection/data_sanitization/host_collector_diagnostics.md`).

**`job.collectNodeMetrics: false`** skips the ClusterRole entirely. The script still runs and writes the "declined at install" line and uses the metrics API alone, which needs no cluster-scoped grant. The section is never silently empty. With `job.nodeStatsSource: apiServer` the chart refuses to render, since `nodeMetrics` has nothing to fall back to.

##### Rejected alternatives for container memory and CPU

These were evaluated and ruled out for `mode: job`; the reasoning is recorded so they aren't re-proposed without answering it.

- **The router's Prometheus endpoint (`process_resident_memory_bytes`, `process_cpu_seconds_total`).** The router does not serve them. Checked directly against v1.61.0, v2.16.3, v2.17.0, v2.19.0 and v3.0.0-preview.0: the endpoint serves `apollo_router_*` families and `target_info`, and the jemalloc gauges from v2.16.3 onward, but no `process_*` series. The v2.19.0 source agrees: it has no `process_*` metric names and no process-metrics crate, and its `sysinfo` dependency feeds only the diagnostics plugin and the always-on fleet detector's static `apollo.router.instance.*` host gauges (CPU count, frequency, total memory), which the public meter provider that Prometheus reads explicitly filters out. The jemalloc gauges are collected, and describe the allocator rather than the container. They are compiled in only for unix builds with the `global-allocator` feature, which the official images use.
- **`exec` into the router container to read cgroup files.** Rejected by `specs/architecture.md`: nothing in the base spec may run inside the router container, because it draws on the container's own cgroup allocation and so could worsen the problem it is diagnosing. `exec` also runs in a single pod, and `pods/exec` is itself a broad grant.
- **`nodeMetrics` (the API server's proxy) as the `mode: job` default.** It needs `nodes/proxy`, which Kubernetes documents as not read-only and as authorizing command execution in any container on the node. It is kept as an explicit opt-in, `job.nodeStatsSource: apiServer`, because it is the only route that works when the Job's pod can't reach the kubelet and metrics-server isn't installed. In `mode: local` it is the only route, and the invoking user's own credentials decide what is allowed.
- **metrics-server (`metrics.k8s.io`) as the only source.** Works with a namespaced Role and no cluster-scoped grant, but needs metrics-server installed and returns only working set and a CPU rate: no RSS, page faults or pressure stall data. Adopted as the fallback tier ([Sources and fallback](#sources-and-fallback)), not as the primary source.
- **A customer's own Prometheus server.** The only source of real history rather than one sample per run, but it needs a customer-supplied endpoint and credentials, which the on-demand flow doesn't have.
- **cAdvisor only, dropping the Summary API.** cAdvisor lacks the kubelet-computed CPU rate (`usageNanoCores`) and `availableBytes`, so a single sample would give cumulative CPU only.

##### Required before this is considered done

The direct-kubelet route has been checked only on one Kubernetes version (v1.37.0, in kind). Before the spec is treated as met:

- **Grant boundaries.** On a cluster, a service account holding only `nodes/stats` reads `/stats/summary` directly and is refused (`403`) on the API server's proxy path. One holding only `nodes/metrics` reads `/metrics/cadvisor` and is refused on `/stats/summary`. A service account holding neither is refused on both. (Observed once in kind; repeat as part of the chainsaw test below.)
- **Positive control, job mode.** A chainsaw job-mode test with the grants present asserts the router container's `memory.*`, `cpu.*` and `psi` fields in `stats-summary.json`, using the same spec-derived check as `testing/chainsaw/scripts/assert_documented_memory_cpu_signals.sh`, extended to read this location. RTF cannot supply this: its environment can't be granted cluster-scoped roles, so every RTF job scenario declines.
- **Filtering.** With a second workload on the router's node, the bundle contains the router pods' entries and none of the other workload's.
- **Each named reason.** A scenario for every row of the table above, including `job.collectNodeMetrics: false`, a Pending pod, a NetworkPolicy that blocks the kubelet port, and a ClusterRole without `nodes/stats`.
- **Reachability on managed clusters.** Both routes are exercised on at least EKS, GKE and AKS, with the result recorded here: the kubelet on `10250` from the Job's pod, and the metrics API. Until then neither route's availability on those platforms is verified. What the providers' documentation says, none of it a substitute for a run: EKS and GKE Standard allow pod-to-node traffic on `10250` by default, and AKS allows all pod traffic unless a NetworkPolicy or NSG changes that. A deny-all egress NetworkPolicy breaks the kubelet route on all three. metrics-server is documented as not installed by default on EKS and is undocumented on GKE and AKS. None of the three documents the kubelet's authorization settings, so whether it accepts a ServiceAccount token on `10250` must be tested. The routes are weakest on EKS Fargate (port `10250` is reserved and there is no node host), GKE Autopilot (which states that node-level access is unsupported and may be removed without notice) and AKS virtual nodes (not documented to serve the kubelet API). Pods there should be expected to use the metrics API, or to come back with a named reason.
- **Fallback.** A positive control with the kubelet unreachable (a NetworkPolicy blocking its port) and metrics-server installed asserts `metrics-api.json` is populated for the router's pods and `stats-summary.json` is absent for that node. The same scenario without metrics-server asserts the `metrics.k8s.io not found` line.
- **`apiServer` source.** A chainsaw job-mode positive control with `job.nodeStatsSource: apiServer` asserts `node-metrics/*.json` holds the router container's fields, and that the chart refuses to render with `job.collectNodeMetrics: false`.
- **Cost of the cAdvisor read.** The payload size and time on a busy node are measured and recorded here before `job.collectCadvisorMetrics` is recommended to customers.
- **`helm template`.** The rendered spec is identical under `helm install` and `helm template`, and a collection under ArgoCD produces the same files.
- **`APOLLO_KEY` absent**, and the bearer token absent from the bundle, in every scenario above.

## Service mesh and proxy environments

Some customers run a service mesh or proxy (Istio, Linkerd, Envoy) as a sidecar alongside the router. The proxy itself can be the root cause of what looks like a router problem. The `logs` collector captures every container in the pod, and the kubelet Summary API reports per-container figures, so a sidecar's own resource usage is visible alongside the router's.

A mesh enforcing strict mTLS can block the Prometheus scrape. No pod responds, so the bundle has no per-pod metrics files and writes the "no pod responded" line from the table above — the same line a `listen`-address misconfiguration produces. The bundle alone can't tell you which.
