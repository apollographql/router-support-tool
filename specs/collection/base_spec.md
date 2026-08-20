# Data Collected

The default collection spec is grounded in a TSH ticket analysis of the past year's support tickets and feedback from support and router engineers.

## What the base spec collects

These items are collected in the base spec and address the most common first-round support asks. The table below documents what is collected, how, and the permissions each collector needs. This is designed to be shared directly with customers — a platform team can review it, grant the access required for the collectors they want, and understand exactly what each one provides and what's lost if they decline it. Nothing is collected that isn't listed here.

Shipping capabilities as separate specs, rather than growing a single spec, is motivated by a concrete safety constraint: some collectors (notably `exec`-based ones) run commands inside the router's existing container and consume from its cgroup allocation rather than a separate budget. **The base spec contains none of these** — it runs entirely against the API server, the kubelet, and external endpoints. Heavier collection operations therefore warrant their own spec, with independent controls over when they run. A collector that needs to run inside the container does not belong in the base spec, it belongs in a separate spec with its own trigger and threshold controls. 

This spec declares collectors and redactors only. **The base spec ships no analyzers** — the bundle is raw material for a support engineer, not a diagnosis.

Every bundle also carries a `meta.json` recording what the tool was configured to do — see `specs/collection/meta_json.md`. It does not, and structurally cannot, record why any given section came up empty: that requires working out from the bundle directly, using the reasoning in this file, not from a pre-declared list.

**Collector names follow the conventions in `specs/collection/collector_naming.md`, which also lists the assigned name for every collector below.** This is not a style preference: troubleshoot.sh names the bundle's directories after the collector name, so the naming convention *is* the bundle's directory layout. Adding a collector means picking its name from that convention, and renaming one is a breaking change for anything that reads a bundle path.

**Every reference in this file to "the official Apollo router Helm chart" is pinned to `v2.17.0`**, the same way collection-engine references are pinned to troubleshoot.sh `v0.120.0` (see below). The chart deliberately keeps its `version` and `appVersion` identical to the router release it packages, so this pin identifies both at once. Unlike the engine version, this project has not declared a minimum supported router chart version — `v2.17.0` is cited only because it's what was checked. Re-verify against whatever version is actually current if a claim here is ever load-bearing for a decision.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| Pod status, restart counts, resource limits | k8s API | `clusterResources` collector | API server CPU | Whether pods are healthy, restart count, resource limits configured | k8s control plane | **Must be scoped with `namespaces: [<namespace>]`** — this collector defaults to every namespace in the cluster, and it collects ConfigMaps with their full `data`. See `specs/deployment/v1/v1.md` → Deployment tiers. |
| Runtime logs | Container log stream | `logs` collector | Network bandwidth | Recent router output, plus crash output from the previous container when one exists | Cluster network | Collected per pod, captures all containers in the pod (including proxy/mesh sidecars). **Previous-container logs are always collected**, written to `<name>-previous.log` — not an opt-in. How far back and how much is bounded by `logs.maxAge` / `logs.maxLines`, defined in `specs/deployment/v1/v1.md` → Chart values |
| Full Prometheus metrics snapshot | Router metrics endpoint | `http` collector | Network, router HTTP handler | Complete operational metrics — request rates, error rates, latency, traffic shaping state | Router network | Requires Prometheus endpoint enabled in `router.yaml`. See [Prometheus metrics: fixed port, tier-dependent](#prometheus-metrics-fixed-port-tier-dependent) below. |
| Sanitized `router.yaml` | ConfigMap holding the rendered config | `helm` + `configMap` collectors | API server CPU | Full router configuration — traffic shaping, timeouts, plugins, feature flags | k8s control plane | Captures config as written, not effective config (env-var overrides not included). Custom redactors strip JWT keys, auth config, and inline secrets. See [`router.yaml` capture](#routeryaml-capture) below. |
| `Router deployment env vars: APOLLO_GRAPH_REF, APOLLO_ROUTER_OFFICIAL_HELM_CHART` | Pod spec (`spec.containers[].env`) | `clusterResources` collector | API server CPU — no additional call, this data is already in the pod list | Graph ref for bundle tagging, whether the router was deployed via Apollo's official Helm chart | k8s control plane | Read from the declared pod spec, **not** by exec — see [Router env vars](#router-env-vars) below. `APOLLO_KEY` is a `secretKeyRef` in the pod spec, so it is structurally absent from this data |
| Router version | Container image tag | `clusterResources` collector | API server CPU | Router version for bundle tagging | k8s control plane |  |
| Not collected: Redis health | Redis directly | `redis` collector | — | Would have given reachability (`isConnected`) and Redis server `version` — not latency | — | **Not in the base spec.** The collector requires an inline connection URI that no tier can supply safely. See [Redis health: not collected](#redis-health-not-collected) below. Redis errors still appear in router logs, and the Redis config block still appears in the collected `router.yaml` |

### `router.yaml` capture

Two collectors run unconditionally to capture configuration, because no single mechanism works across every supported deployment tier:

- **`helm` collector** (`collectValues: true`) — reads the Helm release values. Populates when the customer deployed via Helm; captures the values layer, which may or may not equal the fully rendered config depending on chart structure.
- **`configMap` collector** — reads the ConfigMap holding the rendered `configuration.yaml` directly, targeted by label selector (`app.kubernetes.io/name=router`) rather than by an exact ConfigMap name. This is what makes it work without knowing the customer's Helm release name in advance.

Both run in every collection. Whichever mechanism matches the customer's deployment populates; the other returns empty — consistent with the base spec's general graceful-degradation behavior.

For the **official Apollo router Helm chart**, the `configMap` collector succeeds directly: the chart's ConfigMap carries the standard `app.kubernetes.io/name=router` label, and the ConfigMap name is always the Helm release name, so label-based targeting finds it with no customer-supplied release name, selector, or ConfigMap name required.

For **other Helm-based deployments**, the `helm` collector is more likely to succeed, since it does not depend on the deployment following the official chart's specific labeling convention.

For **raw-manifest or other custom deployments**, neither collector can succeed on convention alone — the customer supplies the ConfigMap name and pod selector as chart values, and the `configMap` collector targets by those instead. This tier is supported in v1; it just requires more from the customer. See `specs/deployment/v1/v1.md` → Chart values for the `selector`/`configMapName` definitions.

**This assumes one router release per namespace.** Label-based targeting matches on `app.kubernetes.io/name=router` alone — it does not also filter by `app.kubernetes.io/instance` (the per-release label the chart also sets). Verified against the collector's actual behavior on a selector match ([`configmap.go` `listConfigMapsForSelector`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/configmap.go), checked at both the declared floor `v0.120.0` and the current latest release `v0.129.3` — byte-for-byte identical, so this holds regardless of whether collection runs against the pinned floor or whatever `krew` currently installs): it is not an arbitrary single pick — every ConfigMap matching the label is collected, each written to its own file named after the real ConfigMap name, so nothing is silently dropped or overwritten. But if a customer runs more than one router release in the same namespace - e.g. one release per graph — every release's full configuration is swept in, not just the one the customer meant to diagnose. Each is separately named, so a support engineer — or the customer, inspecting the bundle before sharing it, as with any other section — can tell them apart.

This can't be recorded in `meta.json` at all — whether a second release exists isn't known at render time. `specs/collection/meta_json.md` → Multiple router releases in one namespace explains why, and what's observable instead (the `configMap` collector's per-match file count). Narrowing the selector itself to a specific release is a chart-values concern for `specs/deployment/`, not this file.

### Where graph schema/SDL actually lands, and why it is sometimes absent for a reason that has nothing to do with redaction

Schema/SDL is the one redaction customers can configure: included by default, with opt-out via the `redaction.includeSchema` chart value — see `specs/deployment/v1/v1.md` → Chart values for its definition. Everything else the base spec redacts is fixed, with no customer configuration.

Schema/SDL being a customer-configurable redactor (`redaction.includeSchema`) implies there is a schema *collector* the redactor attaches to. There is not. Verified against [`templates/supergraph-cm.yaml`](https://github.com/apollographql/router/blob/v2.17.0/helm/chart/router/templates/supergraph-cm.yaml):

- Schema/SDL, when the chart puts it in the cluster at all, lands in a **separate ConfigMap**, `<release>-supergraph` — distinct from the main config ConfigMap (`<release>`) that `router.yaml` capture reads.
- **It renders only when the customer sets `.Values.supergraphFile`** — i.e., only for customers who hand the chart a local supergraph file at install time. Customers on managed federation, who supply `APOLLO_GRAPH_REF`/`APOLLO_KEY` and let the router fetch the supergraph from Uplink/GraphOS at runtime, never populate this ConfigMap. For that population, **schema is absent from the cluster regardless of `redaction.includeSchema`** — the setting has nothing to redact.
- It carries the same `app.kubernetes.io/name=router` label as every other chart resource (`router.labels` includes `router.selectorLabels`, which sets it), so it is swept up by the same `clusterResources` ConfigMap collection as everything else in the namespace — landing at `cluster-resources/configmaps/<namespace>.json`, alongside the main config ConfigMap, not at any schema-specific path.

### Router env vars

**The base spec contains no `exec` collector.** `APOLLO_GRAPH_REF` and `APOLLO_ROUTER_OFFICIAL_HELM_CHART` are read from the pod spec that `clusterResources` already collects, which makes an `exec` collector unnecessary for them.

Both halves are verified:

- **The values are in the pod spec.** From [`templates/deployment.yaml#L78`](https://github.com/apollographql/router/blob/v2.17.0/helm/chart/router/templates/deployment.yaml#L78): `APOLLO_ROUTER_OFFICIAL_HELM_CHART` is set as `value: "true"`, and (at [`#L90`](https://github.com/apollographql/router/blob/v2.17.0/helm/chart/router/templates/deployment.yaml#L90)) `APOLLO_GRAPH_REF` as `value: {{ .Values.managedFederation.graphRef }}` — both plain literals on the container, not references.
- **`clusterResources` collects them.** Its [`pods()`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L473) function lists full `Pod` objects with no field filtering and marshals the entire list to `cluster-resources/pods/<namespace>.json`, `spec.containers[].env` included.

#### The two mechanisms, side by side

Both approaches read the same two variables. They differ in where they read from, and every difference below favoured one side or the other in the decision:

| | `exec` into the container | Pod-spec read via `clusterResources` |
| --- | --- | --- |
| **What it reads** | The *resolved* environment the process actually has | The *declared* environment in `spec.containers[].env` |
| **Where it runs** | Inside the router container, consuming its cgroup allocation | Against the API server; nothing enters the container |
| **RBAC required** | `pods/exec` — the only thing in the base spec needing it | None beyond the `pods` read already required |
| **Behavior against a degraded router** | Can fail or hang on an OOM-killed, crash-looping, or unresponsive container | Unaffected — pod objects are served by the API server regardless of container health |
| **Fleet coverage** | One arbitrarily-selected pod when the selector matches several | Every pod in the namespace |
| **Extra collection cost** | An additional call into the cluster | None — the pod list is collected anyway |
| **Image dependency** | Needs a runnable binary in the image; a distroless image may have none | None |
| **Indirected values (`valueFrom`, `envFrom`)** | Resolves them, including from Secrets | Sees the reference only |
| **Respects customer indirection** | No — pulls Secret-held values into the bundle regardless | Yes |
| **Collection timestamp** | Near-free — `date -u` appended to the command it already runs, giving a UTC value from the router container's own clock | Not available; the bundle's directory name is the only timestamp |

Weighing the tradeoff:

| | Pros | Cons |
| --- | --- | --- |
| **`exec` into the container** | Resolves indirected values (`valueFrom`/`envFrom`, including Secrets); would give a free, UTC-explicit collection timestamp | Requires `pods/exec` RBAC — the only thing in the base spec that would need it; runs inside the router container, so it can fail or hang on exactly the OOM-killed, crash-looping, or unresponsive pod a support bundle exists to diagnose; arbitrary single-pod pick when a selector matches several; needs a runnable binary in the image; overrides a customer's choice to keep a value in a Secret |
| **Pod-spec read via `clusterResources`** (chosen) | No extra RBAC; unaffected by container health; covers every pod in the namespace, not one; free — the pod list is already collected; respects a customer's Secret indirection | Sees indirected values (`valueFrom`/`envFrom`) as references only, not resolved; no collection timestamp available |

**The decision turns on container health, not permissions or cost.** Neither of `exec`'s two advantages helps when the router is OOM-killed or crash-looping — the situation a support bundle exists for — and both are paid for with `pods/exec` and with in-container execution. A precise timestamp from a mechanism that may fail exactly when it matters is worth less than an imprecise one that always works, especially since the collected logs and metrics already carry precise, zone-aware times at higher resolution. This also makes the base spec entirely external: with no `exec` collector, *nothing in it executes inside the router container*, so "safe to run against a degraded router" is an invariant rather than a claim with a justified exception.

It also confirms the `APOLLO_KEY` guarantee from a third direction: in the same chart template, `APOLLO_KEY` is a `valueFrom.secretKeyRef`, so even a full pod-spec dump exposes only the Secret name and key, never the value.

#### The residual gap, by tier

Pod specs record env vars as *declared*; `exec` would read them as *resolved*. That difference only bites when a value is supplied indirectly — and it affects the two variables differently.

**`APOLLO_ROUTER_OFFICIAL_HELM_CHART` — nothing is lost, at any tier.** Its job is to identify the deployment type, and non-official-chart deployments do not set it at all, so **absence is the signal.** Pod-spec reading and `exec` report it identically: present and `"true"` means official chart, absent means not.

**`APOLLO_GRAPH_REF` on the official chart: also nothing is lost, by construction, not by observed likelihood.** The chart has exactly one field for it, `managedFederation.graphRef`, and that field renders **only** as a plain `value:` — there is no chart-native option that puts the graph ref behind a `valueFrom` or `envFrom`, unlike `APOLLO_KEY`, which explicitly supports `existingSecret`. So for any customer using the chart's own documented interface, the graph ref is a literal in the pod spec, full stop, and `clusterResources`'s unfiltered pod list always captures it (given the `pods` read the base spec already requires).

The table below applies only to a customer who deliberately steps outside that interface — using the chart's generic `extraEnvVars`/`extraEnvVarsCM`/`extraEnvVarsSecret` escape hatches to inject `APOLLO_GRAPH_REF` some other way instead of setting `managedFederation.graphRef`:

| How the customer supplies it | Pod-spec read | Recoverable from the bundle at all? |
| --- | --- | --- |
| `managedFederation.graphRef` (the chart's own field) | Works | Yes — always, this is the only path the chart itself produces |
| `extraEnvVars` with `envFrom` a ConfigMap | Shows the ConfigMap name only | **Yes** — `clusterResources` collects ConfigMaps with their `data`, so the value is in the bundle, just in a different file |
| `extraEnvVars` with `valueFrom` a Secret | Shows the reference only | No — and deliberately so, see below |

**The Secret case is a reason to prefer this approach, not a cost of it.** A customer who puts their graph ref in a Secret has chosen to treat it as sensitive. `exec` reads the resolved environment and would pull that value into the bundle regardless of that choice; the pod-spec read respects it. Given that this tool's central promise is that it is safe to run, silently overriding a customer's own indirection is the wrong default.

**A further argument against `exec` for exactly these customers:** `exec` depends on the container image shipping a binary it can run. A slim or distroless router image may not, and that failure would be silent in the same way as everything else here. Reading the pod spec has no such dependency. (Not verified against Apollo's published router images — noted as a consideration, not a finding.)

### Prometheus metrics: fixed port, tier-dependent

The `http` collector targets the metrics endpoint at a **fixed port confirmed from the official chart's [`values.yaml#L73`](https://github.com/apollographql/router/blob/v2.17.0/helm/chart/router/values.yaml#L73)** (`containerPorts.metrics: 9090`), not a port discovered from the customer's configuration. This port cannot be inferred from customer-supplied config the way the ConfigMap collectors above can fall back to labels — there is no equivalent discovery mechanism for an HTTP target, so the base spec relies on the official chart's known default.

**The collector targets the Service, not a pod.** The `http` collector takes only a static `url` — no selector, no pod discovery — and the spec is rendered once at chart-install time, before any collection runs. A router Deployment has no stable per-pod address to hardcode, so the only viable target is the Service's cluster DNS name (confirmed against the [collector's docs](https://troubleshoot.sh/docs/collect/http)).

That makes three settings load-bearing:

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the bind address. If the exporter is bound to loopback, an external scrape cannot reach it no matter what port the collector targets.
- **`serviceMonitor.enabled: true`.** Confirmed at [`templates/service.yaml#L32`](https://github.com/apollographql/router/blob/v2.17.0/helm/chart/router/templates/service.yaml#L32): the Service's `metrics` port entry is added only inside an `{{- if .Values.serviceMonitor.enabled }}` block. Without it, the Service has no `metrics` port at all, so a Service-targeted scrape fails regardless of whether the exporter itself is on and reachably bound.

If any of the three is off or misconfigured, the collector returns empty; the rest of the bundle is unaffected.

For **raw-manifest and custom deployments**: the port cannot be inferred, so this collector returns empty rather than failing. This tier gets no metrics in v1 by design — the alternative, an optional `metricsPort` chart value, was considered and deferred; see `specs/deployment/v1/v1.md` → Rejected alternatives.

Subgraph health checks and OTel endpoint reachability were considered and not included in the base spec, for the same underlying reason: both would require an HTTP target (a subgraph URL, an OTel collector endpoint) that is customer-specific and has no chart-level default to fall back on, unlike the metrics port. Subgraph health is instead inferable from the router's own `apollo.router.operations.fetch*` metrics, which are already captured by this same Prometheus scrape when enabled.

### Redis health: not collected

**The `redis` collector is not included in the base spec.** Redis connectivity is not collected. The reasoning is recorded in full below, because the collector is an obvious thing to reach for and the reasons against it are not obvious.

#### Why it cannot be targeted

The collector needs a connection URI, and nothing can supply one safely:

- **No discovery of any kind.** Per the [collector documentation](https://troubleshoot.sh/docs/collect/redis/), `uri` is the one required field and must be supplied **inline**. A Kubernetes Secret can back the `tls` block (`cacert`, `clientCert`, `clientKey` via `tls.secret`), but there is no Secret or ConfigMap reference available for the URI itself.
- **No chart-level default to fall back on.** Confirmed against the official chart at `v2.17.0`: it contains **zero** references to Redis — no `redis` or `cache` values in `values.yaml`, no `charts/` subdirectory, no dependency declared in `Chart.yaml`. The customer's Redis is infrastructure the router points at, not infrastructure the chart deploys, so rendering the chart makes nothing inferable. This is strictly worse than the metrics port, which at least has a documented chart default.

#### What is lost

The collector would have given `isConnected`, `error`, and the Redis server `version` — connectivity and version, **not latency**, which would have been a stronger reason to want it. Most of that diagnostic need survives without it: Redis errors appear in the **router logs**, the Redis config block appears in the collected **`router.yaml`** (see below for exactly where), and cache metrics come from the **Prometheus scrape** when enabled. What's actually lost is an independent reachability check and the version string.

#### Where Redis configuration appears in `router.yaml`

Not a single block — the router has three independent Redis-backed caches, each configured under its own path, verified against the router's own config source (`apollographql/router` @ `v2.17.0`):

| Feature | Config path | Source |
| --- | --- | --- |
| Query-plan cache | `supergraph.query_planning.cache.redis` | [`QueryPlanRedisCache`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/configuration/mod.rs#L1032) |
| APQ cache | `apq.router.cache.redis` | [`Apq.router.cache`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/configuration/mod.rs#L907), `Cache.redis` |
| Entity caching | `preview_entity_cache.subgraph.all.redis`, `.subgraphs.<name>.redis` | [`entity.rs` `Config.redis`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/cache/entity.rs#L140) — **note: `preview_entity_cache` is marked deprecated in the router source**, so this path may not be stable across router versions |

All three route through the same underlying shape (`urls`, `username`, `password`, `timeout`, `ttl`, `namespace`, `tls`, `required_to_start`, `reset_ttl`, `pool_size`). None of this is collected by a dedicated mechanism — whichever of these three the customer has enabled rides along in the same `helm`/`configMap` capture as the rest of `router.yaml`, the same way any other config section would.

#### Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| **Optional `redisUri` chart value** | The URI must be supplied inline (no Secret reference option exists for it), so the chart would template a live credential straight into the spec ConfigMap — which [`clusterResources` collects with full, unfiltered `data`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L2125). That's the same posture already ruled out for `APOLLO_KEY`: no redaction rule should be load-bearing for a secret, and a collector that yields one boolean and a version string doesn't justify creating that dependency. A Secret-reference variant doesn't fix it either — Helm would still resolve and template the literal in, same destination, same exposure. Many customers couldn't supply a literal URI anyway: router configs frequently use `${env.REDIS_URL}`, which `helm`/`configMap` capture unresolved. |
| **Infer the URI from collected `router.yaml`** | Not possible with troubleshoot.sh as it stands — collectors don't take input from other collectors' output, and the spec is fully rendered before any collection runs. Config-as-written may also hold `${env.REDIS_URL}` rather than a usable address. |
| **Solve credential handling, revisit later** | Insufficient on its own. The collector would connect from wherever collection *runs* — a laptop for `mode: local`, a Job pod for `mode: job` — not from the router, so reachability there doesn't establish reachability from the router itself. It can mislead in either direction (a NetworkPolicy or mTLS requirement the router hits but a laptop doesn't, or vice versa via VPN routing). Router logs and cache metrics already answer this from the correct vantage point; a future proposal needs to argue why the collector's vantage point is right, not just how the credential would be protected. |

### Namespace scoping is mandatory, not a default

`clusterResources`, `logs`, and `configMap` (when targeted by selector, as the official-chart and other-Helm tiers do) share the same risk: Kubernetes treats an empty namespace as "every namespace" for a list call — not troubleshoot.sh-specific behavior, the same convention `kubectl get pods -A` relies on. Left unscoped, each one sweeps the whole cluster, not just the router's namespace — [**`clusterResources` collects ConfigMaps with their full `data`**](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L2125), so an unscoped run pulls unrelated teams' application config, pods, and logs into a bundle the customer may share with Apollo.

The spec sets the namespace explicitly on all three. Field names differ — `clusterResources` takes `namespaces`, a list, while `logs` and `configMap` take a singular `namespace` string — but the risk of leaving any of them unset is the same. See `specs/deployment/v1/v1.md` → Deployment tiers for how the chart wires the required value into every field shape.

The raw-manifest tier's `configMap` (targeted by name via `configMapName`, not selector) is the one exception: an unset `namespace` there falls back to the kubeconfig context's namespace instead of sweeping the cluster — a narrower, different failure, but still not something to rely on. The spec sets it explicitly there too.

### Why `APOLLO_KEY` cannot appear in a bundle

The claim that `APOLLO_KEY` is never collected rests on mechanism rather than redaction, and both halves are verified:

- **Structural isolation.** [`templates/deployment.yaml#L82`](https://github.com/apollographql/router/blob/v2.17.0/helm/chart/router/templates/deployment.yaml#L82) confirms `APOLLO_KEY` is sourced from a separate Kubernetes Secret (`managedFederationApiKey`), not from the config ConfigMap the tool reads. A ConfigMap read cannot reach it.
- **No collector in the base spec reads Secret data.** `clusterResources` collects ConfigMaps but not Secrets as objects. Its only Secret access is `imagePullSecrets`, which filters to `kubernetes.io/dockerconfigjson` type and extracts the registry and username only — the source explicitly discards the password when splitting the decoded credential. No Secret `data` reaches the bundle.

This is why no redaction rule is load-bearing for `APOLLO_KEY`, and why any future collector that reads Secret data would be a change to this guarantee rather than an incremental addition.

### Memory and CPU information collected

Memory is the most nuanced collection area, because different levels of granularity require fundamentally different mechanisms. What the base spec collects is sufficient to **detect, confirm, and characterize** a memory problem: is memory growing, how fast, how close to the limit, and did the kernel already kill the container. It does not answer *which code path is leaking* — that needs jemalloc heap profiling via the router's diagnostics plugin, which is out of scope for the base spec.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| `memory.workingSetBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | How much memory k8s counts against the limit — the OOM kill threshold | k8s control plane → kubelet | Per node, per pod, per container. \[1\] |
| `memory.rssBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Physical RAM in use | k8s control plane → kubelet | \[1\] |
| `memory.usageBytes`, `memory.availableBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Usage, and headroom remaining against the limit | k8s control plane → kubelet | \[1\] |
| `memory.pageFaults`, `memory.majorPageFaults` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Major faults indicate real paging pressure rather than growth alone | k8s control plane → kubelet | \[1\] |
| `cpu.usageNanoCores`, `cpu.usageCoreNanoSeconds` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | CPU consumed by the router container | k8s control plane → kubelet | \[1\] |
| `cpu.psi`, `memory.psi` (pressure stall information) | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Whether the container is *stalling* on CPU or memory — the contention question CPU throttling was meant to answer | k8s control plane → kubelet | **Conditional, not guaranteed** — absent on Kubernetes 1.32 and below, gated behind `KubeletPSI` and cgroup v2 from 1.33 on. Treat absence as expected on an unknown-version cluster, not a defect. \[2\] |
| Configured `resources.limits` / `requests` | Pod spec | `clusterResources` collector | API server CPU | What the usage numbers above should be compared against | k8s control plane | Already collected as part of the pod list |
| OOM kill **occurrences** | Kubernetes events (`OOMKilling`, evictions) | `clusterResources` collector | API server CPU | That OOM kills happened, when, and how often — customers frequently do not know | k8s control plane | Per-occurrence record, retained as long as the cluster keeps events |
| OOM kill **last state** | Pod status `lastState.terminated.reason: OOMKilled`, `restartCount` | `clusterResources` collector | API server CPU | Whether the most recent restart was an OOM kill, and how many restarts have occurred | k8s control plane | Survives event expiry, unlike the row above — the two are complementary |
| Node `MemoryPressure` / `DiskPressure` conditions | Node objects | `clusterResources` collector | API server CPU | Whether the node itself is under pressure, distinguishing a router problem from a neighbour's | k8s control plane | |
| `process_resident_memory_bytes` | Router Prometheus endpoint | `http` collector | Network, router HTTP handler | Process-level RSS as the router sees it | Router network | Requires the Prometheus exporter enabled and reachably bound. Subject to the fixed-port caveat above. |
| `process_cpu_seconds_total` | Router Prometheus endpoint | `http` collector | Network, router HTTP handler | CPU time consumed by the router process | Router network | Same conditions as the row above |
| **Not collected:** `container_cpu_throttled_seconds_total` | cAdvisor `/metrics/cadvisor` | — | — | Whether the container is hitting its CPU cgroup limit | — | The metric exists in cAdvisor, but no troubleshoot.sh collector reaches that endpoint. `cpu.psi` above is a partial, cluster-dependent substitute — see below. |
| **Not collected:** `container_oom_events_total` | cAdvisor `/metrics/cadvisor` | — | — | A cumulative OOM-event counter | — | Same reason. The two OOM rows above cover the diagnostic need without it. |
| **Not collected:** heap dump `.prof` files | `experimental_diagnostics` plugin | — | — | Which code path / allocation site is holding memory | — | Requires `experimental_diagnostics` enabled and the `supported.rs:219` fix. Would also require in-container execution, which the base spec does not do. |
| **Not collected:** CPU flame graph / pprof | `pprof-rs` | — | — | Which code is consuming CPU | — | Requires router instrumentation; named future gap |

**\[1\]** The Summary API reports per node, per pod, and per container, so signal is correctly separated across every router pod in a fleet. This assumes one router process per container — the standard k8s pattern. Where multiple processes share a container, container-level figures are aggregates and cannot distinguish between them.

**\[2\]** Full version history, feature-gate rollout, and line-cited evidence: see the evidence table below.

#### Why the Summary API and not cAdvisor's metrics endpoint

The kubelet exposes two endpoints carrying container-level resource data, and only one of them is reachable:

| Endpoint | Reached by | Contains |
| --- | --- | --- |
| `/api/v1/nodes/<node>/proxy/stats/summary` | The `nodeMetrics` collector | Per-container CPU and memory as JSON, plus PSI on clusters new enough to populate it \[2\] |
| `/api/v1/nodes/<node>/proxy/metrics/cadvisor` | **No troubleshoot.sh collector** | cAdvisor's Prometheus series, including throttling and OOM counters |

Sources, pinned so the line references stay valid:

| Claim | Evidence |
| --- | --- |
| `nodeMetrics` queries only the Summary API path | [`k8s_node_metrics.go#L18`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/k8s_node_metrics.go#L18) — `summaryUrlTemplate = "/api/v1/nodes/%s/proxy/stats/summary"`, the only endpoint the collector builds |
| The Summary API carries no throttling or OOM fields on kubelet `v0.32.0` (Kubernetes 1.32) | [`stats/v1alpha1/types.go#L218`](https://github.com/kubernetes/kubelet/blob/v0.32.0/pkg/apis/stats/v1alpha1/types.go#L218) (`CPUStats`) and [`#L231`](https://github.com/kubernetes/kubelet/blob/v0.32.0/pkg/apis/stats/v1alpha1/types.go#L231) (`MemoryStats`) — this project has no declared minimum Kubernetes version; `v0.32.0` is cited only because it's what was checked |
| PSI (`cpu.psi`, `memory.psi`) is absent on kubelet `v0.32.0` but present from `v0.33.0` (Kubernetes 1.33) onward | Absent: same `v0.32.0` file above has no `psi` field either. Present: [`stats/v1alpha1/types.go#L252`](https://github.com/kubernetes/kubelet/blob/v0.33.0/pkg/apis/stats/v1alpha1/types.go#L252) (`CPUStats.PSI`) and [`#L277`](https://github.com/kubernetes/kubelet/blob/v0.33.0/pkg/apis/stats/v1alpha1/types.go#L277) (`MemoryStats.PSI`) |
| Populating that field requires the `KubeletPSI` feature gate — alpha/off-by-default in 1.33, beta/on-by-default from 1.34 | [`kube_features.go#L598`](https://github.com/kubernetes/kubernetes/blob/v1.34.0/pkg/features/kube_features.go#L598) (declaration) and [`#L1530`](https://github.com/kubernetes/kubernetes/blob/v1.34.0/pkg/features/kube_features.go#L1530) (versioned spec) |
| No collector named `containerMetrics` exists | [`collector_shared.go#L320`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/apis/troubleshoot/v1beta2/collector_shared.go#L320) — the `Collect` struct is the complete list of collectors the engine accepts |

References are pinned to troubleshoot.sh `v0.120.0` (the declared minimum for the engine — see `specs/deployment/v1/v1.md` → Collection engine version) and, for claims about the kubelet API itself, `k8s.io/kubelet` `v0.32.0`/`v0.33.0` and `k8s.io/kubernetes` `v1.34.0` — versions chosen only because they're where a claim was actually checked, not because a minimum Kubernetes version has been declared for this project. **Re-check the troubleshoot.sh citations whenever the declared minimum engine version changes**, and re-check the kubelet citations if this project ever declares a minimum Kubernetes version — either kind of change is exactly what would reopen a decision recorded here.

**Why not just point the `http` collector at `/metrics/cadvisor`?** That path goes through the API server and requires authentication, and the `http` collector's `get` supports only static `headers` ([`collector_shared.go#L185`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/apis/troubleshoot/v1beta2/collector_shared.go#L185)), so a bearer token would have to be a literal templated into the spec ConfigMap — the same prohibition that rules out `redisUri`, and worse, since [`clusterResources` collects that ConfigMap with full, unfiltered `data`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L2125). See `specs/deployment/v1/v1.md` → Chart values.

#### What this costs, and what it does not

Excluding the two cAdvisor counters isn't symmetric:

- **OOM detection is not weakened.** Events plus pod status give occurrence, timing, count, and whether the latest restart was an OOM kill. The counter would have been one number; this is a record.
- **CPU contention has a substitute only where `cpu.psi` populates** (\[2\] above). Where it doesn't, `cpu.usageNanoCores` shows usage, not contention, and there is no substitute: whether the router is CPU-throttled is genuinely not answerable from the bundle. Do not assume PSI is present — check the raw `nodeMetrics` output rather than treating its absence as a defect. `meta.json` has nothing to say about this one: PSI's availability depends on the cluster's Kubernetes version and `KubeletPSI` feature-gate state, neither of which is a value the chart ever receives.

#### RBAC: what `nodeMetrics` actually requires

`nodeMetrics` needs **three** separate grants to reach `/api/v1/nodes/<node>/proxy/stats/summary`, the exact endpoint it calls — not two:

- **`nodes` (list)** — to resolve node names when neither `nodeNames` nor `selector` is set.
- **`nodes/proxy` (get)** — required unconditionally by the API server for any request matching the `/nodes/{name}/proxy/{path}` URL pattern, regardless of what follows `proxy/`. Confirmed from [`pkg/registry/core/node/rest/proxy.go`](https://github.com/kubernetes/kubernetes/blob/master/pkg/registry/core/node/rest/proxy.go) — this is a fixed subresource handler, not aware of the specific path.
- **`nodes/stats` (get)** — required *separately* by the kubelet's own internal authorization check, specifically for `/stats/*` paths. This is layered **on top of** `nodes/proxy`, not a substitute for it — confirmed from [`pkg/kubelet/server/auth.go`](https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/server/auth.go), and this split has existed since kubelet authn/authz was first wired up in 2016 ("Wire kubelet authn/authz"), not a recent or opt-in behavior.

**Open, pending empirical verification:** no prior version of this spec documented `nodes/stats` as required, only `nodes/proxy` and `nodes`. If that's genuinely all that was ever granted in practice, `nodeMetrics` should have been failing with a 403 from the kubelet on any cluster running standard Webhook-mode kubelet authorization — effectively every real cluster (EKS, GKE, AKS, kubeadm, kOps all default to it). Confirm this against a real cluster before treating the three-permission list above as final: grant only `nodes` + `nodes/proxy` and see whether `nodeMetrics` actually succeeds or fails.

**`nodes/proxy` is not a modest step up from a plain `nodes` read — say so plainly, not as a hedge.** Per [Kubernetes' own RBAC good-practices documentation](https://kubernetes.io/docs/concepts/security/rbac-good-practices/): "permission to **get** `nodes/proxy` provides access to privileged kubelet APIs that can retrieve container logs or execute and attach to pod processes, even when a caller does not have the equivalent permissions through the Kubernetes API... This access bypasses audit logging and admission control... **get** permission on `nodes/proxy` is not a read-only permission." In practice, a customer granting this is granting log-read and exec/attach access to every pod on any node the caller can target, bypassing normal RBAC and audit logging for those actions — not a capability narrowed to what this tool happens to use. The permission itself carries no way to restrict that to just `/stats/summary`; `nodes/stats` (above) narrows *what the kubelet will actually serve*, not what `nodes/proxy` itself grants at the API server.

It is worth being precise about why it is requested anyway, so a customer can decline it knowingly: **this grant buys pre-OOM memory trajectory for customers who have not enabled the Prometheus exporter.** That is the "is memory growing, how fast, how close to the limit" question, and for those customers there is no other source for it. Whether that diagnostic value is worth asking for a permission this broad is a real tradeoff — worth a design conversation, not settled by this spec.

Declining `nodes/proxy` (and therefore `nodes/stats`, which is meaningless without it) leaves intact: OOM kill occurrences and last state, restart counts, configured limits, node pressure conditions, and — when the exporter is enabled — process-level memory and CPU from the router itself. What is lost is container-level usage over time when Prometheus is off.

**`nodeMetrics` cannot be scoped to the router's nodes.** Its `selector` matches *nodes* by label, not pods, and the chart cannot enumerate node names at render time. So this collector inherently reads beyond the router's namespace, which is the underlying reason the permission is cluster-scoped rather than a quirk of how it is written. See `specs/deployment/v1/v1.md` → Permissions.

## Service mesh and proxy environments

Some customers run a service mesh or proxy (Istio, Linkerd, Envoy) as a sidecar alongside the router. Two things to note:

* The proxy itself can be the root cause of what looks like a router problem — a throttled or OOMing sidecar, mTLS failures, or Envoy circuit-breaking present as router latency or subgraph failures. To catch this, the `logs` collector captures all containers in the pod, not just the router, and the kubelet Summary API reports per-container figures, so a sidecar's own memory and CPU are visible alongside the router's.

* **The proxy can block a collector, and when it does the result is an empty section rather than an error.** A mesh enforcing strict mTLS intercepts inbound traffic to the pod, so a scrape originating outside the mesh — from the invoking user's machine in `mode: local`, or from a Job pod without a sidecar — can be rejected at the sidecar before the router ever sees it. Collection degrades gracefully, as designed: the run continues and the rest of the bundle is unaffected. But the failure is silent, so it needs to be recognizable.

  Only the **Prometheus metrics scrape** is meaningfully exposed to this. It is the one collector in the base spec that talks directly to a router port. Everything else reaches its data through the Kubernetes API server or the kubelet — `logs`, `clusterResources`, `nodeMetrics`, `configMap` — which a service mesh does not sit in front of.

  **The resulting ambiguity matters for triage.** An empty metrics section caused by mesh interception looks identical to one caused by the exporter being disabled, bound to loopback, or listening on a non-default port. The collected `router.yaml` is what separates them: if `telemetry.exporters.metrics.prometheus.enabled: true` is present in the config and the metrics section is still empty, the exporter was on and something prevented the scrape from landing — a mesh policy, the bind address, or the port. That inference only works because config and metrics are collected together, which is an argument for keeping them in the same spec.

Whether the `mode: job` pod joins the mesh is a deployment decision, not a collection one — it is specified in `specs/deployment/v1/v1.md` → Service mesh environments. The outcome relevant here: the Job runs *outside* the mesh, so a mesh-enforced scrape failure behaves the same way in both modes. `meta.json`'s `sidecar_injection_disabled` field records that fact, but it only rules out one specific cause — interception due to the Job's own mesh non-membership — not whether a mesh issue exists at all. It doesn't, on its own, make the metrics section attributable; the `router.yaml`-based disambiguation above is what actually does that.
