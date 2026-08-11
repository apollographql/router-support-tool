# Data Collected

The default collection spec is grounded in a TSH ticket analysis of the past year's support tickets and feedback from support and router engineers. The ticket analysis revealed a consistent pattern: the highest-leverage data to collect is not exotic, it's the routine data that support has to ask for in the first round of every ticket and almost never receives upfront. Version, graph ID, full config. These items eliminate the first two or three rounds of back-and-forth from virtually every ticket.

## What the base spec collects

These items are collected in the base spec and address the most common first-round support asks. The table below documents what is collected, how, and the permissions each collector needs. This is designed to be shared directly with customers — a platform team can review it, grant the access required for the collectors they want, and understand exactly what each one provides and what's lost if they decline it. Nothing is collected that isn't listed here.

This spec declares collectors and redactors only. **v1 ships no analyzers** — the bundle is raw material for a support engineer, not a diagnosis; see `specs/versions/v1.md` → Analyzers are out of scope for v1.

Every bundle also carries a `meta.json` recording what the tool was configured to do and which empty sections are expected — see `specs/collection/meta_json.md`. That file is what makes an empty section here attributable rather than mysterious.

**Collector names follow the conventions in `specs/collection/collector_naming.md`, which also lists the assigned name for every collector below.** This is not a style preference: troubleshoot.sh names the bundle's directories after the collector name, so the naming convention *is* the bundle's directory layout. Adding a collector means picking its name from that convention, and renaming one is a breaking change for anything that reads a bundle path.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| Pod status, restart counts, resource limits | k8s API | `clusterResources` collector | API server CPU | Whether pods are healthy, restart count, resource limits configured | k8s control plane | **Must be scoped with `namespaces: [<namespace>]`** — this collector defaults to every namespace in the cluster, and it collects ConfigMaps with their full `data`. See `specs/deployment/v1/v1.md` → Deployment tiers. |
| Runtime logs | Container log stream | `logs` collector | Network bandwidth | Recent router output, plus crash output from the previous container when one exists | Cluster network | Collected per pod, captures all containers in the pod (including proxy/mesh sidecars). **Previous-container logs are always collected**, written to `<name>-previous.log` — not an opt-in. How far back and how much is bounded by `logs.maxAge` / `logs.maxLines`, defined in `specs/deployment/v1/v1.md` → Chart values |
| Full Prometheus metrics snapshot | Router metrics endpoint | `http` collector | Network, router HTTP handler | Complete operational metrics — request rates, error rates, latency, traffic shaping state | Router network | Requires Prometheus endpoint enabled in `router.yaml`. See [Prometheus metrics: fixed port, tier-dependent](#prometheus-metrics-fixed-port-tier-dependent) below. |
| Sanitized `router.yaml` | ConfigMap holding the rendered config | `helm` + `configMap` collectors | API server CPU | Full router configuration — traffic shaping, timeouts, plugins, feature flags | k8s control plane | Captures config as written, not effective config (env-var overrides not included). Custom redactors strip JWT keys, auth config, and inline secrets. See [`router.yaml` capture: two collectors, deployment-tier dependent](#routeryaml-capture-two-collectors-deployment-tier-dependent) below. |
| `Router deployment env vars: APOLLO_GRAPH_REF, APOLLO_ROUTER_OFFICIAL_HELM_CHART` | Pod spec (`spec.containers[].env`) | `clusterResources` collector | API server CPU — no additional call, this data is already in the pod list | Graph ref for bundle tagging, whether the router was deployed via Apollo's official Helm chart | k8s control plane | Read from the declared pod spec, **not** by exec — see [Router env vars: read from the pod spec](#router-env-vars-read-from-the-pod-spec-not-by-exec) below. `APOLLO_KEY` is a `secretKeyRef` in the pod spec, so it is structurally absent from this data |
| Router version | Container image tag | `clusterResources` collector | API server CPU | Router version for bundle tagging | k8s control plane |  |
| Not collected: Redis health | Redis directly | `redis` collector | — | Would have given reachability (`isConnected`) and Redis server `version` — not latency | — | **Not in the v1 base spec.** The collector requires an inline connection URI that no tier can supply safely. See [Redis health: not collected in v1](#redis-health-not-collected-in-v1--decided) below. Redis errors still appear in router logs, and the Redis config block still appears in the collected `router.yaml` |

### `router.yaml` capture: two collectors, deployment-tier dependent

Two collectors run unconditionally to capture configuration, because no single mechanism works across every supported deployment tier:

- **`helm` collector** (`collectValues: true`) — reads the Helm release values. Populates when the customer deployed via Helm; captures the values layer, which may or may not equal the fully rendered config depending on chart structure.
- **`configMap` collector** — reads the ConfigMap holding the rendered `configuration.yaml` directly, targeted by label selector (`app.kubernetes.io/name=router`) rather than by an exact ConfigMap name. This is what makes it work without knowing the customer's Helm release name in advance.

Both run in every collection. Whichever mechanism matches the customer's deployment populates; the other returns empty — consistent with the base spec's general graceful-degradation behavior.

For the **official Apollo router Helm chart**, the `configMap` collector succeeds directly: the chart's ConfigMap carries the standard `app.kubernetes.io/name=router` label, and the ConfigMap name is always the Helm release name, so label-based targeting finds it with no customer-supplied release name, selector, or ConfigMap name required.

For **other Helm-based deployments**, the `helm` collector is more likely to succeed, since it does not depend on the deployment following the official chart's specific labeling convention.

For **raw-manifest or other custom deployments**, neither collector can succeed on convention alone — the customer supplies the ConfigMap name and pod selector as chart values, and the `configMap` collector targets by those instead. This tier is supported in v1; it just requires more from the customer. See `specs/deployment/v1/v1.md`.

### Router env vars: read from the pod spec, not by exec

**The base spec contains no `exec` collector.** `APOLLO_GRAPH_REF` and `APOLLO_ROUTER_OFFICIAL_HELM_CHART` are read from the pod spec that `clusterResources` already collects, which makes an `exec` collector unnecessary for them.

Both halves are verified:

- **The values are in the pod spec.** From the official chart's `templates/deployment.yaml`: `APOLLO_ROUTER_OFFICIAL_HELM_CHART` is set as `value: "true"`, and `APOLLO_GRAPH_REF` as `value: {{ .Values.managedFederation.graphRef }}` — both plain literals on the container, not references.
- **`clusterResources` collects them.** Its [`pods()` function](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L473) lists full `Pod` objects and marshals the entire list, with no field filtering, to `cluster-resources/pods/<namespace>.json`. `spec.containers[].env` is included.

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

**`exec` genuinely wins two rows**, and both are real losses rather than rounding errors:

1. **It resolves indirected values.** A graph ref supplied via `valueFrom` or `envFrom` is a literal to `exec` and a reference to the pod-spec read. Detailed by tier below.
2. **It would have given us a proper collection timestamp for free.** Appending `date -u` to the command it already runs costs no extra call and no extra permission, and produces a UTC value from the router container's own clock — the same clock that stamps the router's logs, which is what a support engineer wants when lining a bundle up against an incident timeline. Dropping `exec` gives that up: the bundle's directory name becomes the only timestamp, and it has no timezone. See `specs/collection/meta_json.md` → Collection time, where that option is recorded as rejected *because of this decision*.

The pod-spec read wins on permissions, on reliability in the degraded case that motivates the entire tool, on fleet coverage, on cost, and on respecting a customer's decision to keep a value in a Secret.

**The decision turns on the second column's fourth row.** Neither of `exec`'s advantages helps when the router is OOM-killed or crash-looping — the situation a support bundle exists for — and both are paid for with `pods/exec` and with in-container execution. A precise timestamp obtained from a mechanism that may fail exactly when it matters is worth less than an imprecise one that always works, particularly when the collected logs and metrics carry precise, zone-aware times at higher resolution anyway.

**If this is revisited, the timestamp is the stronger argument, not the env vars.** The env-var gap has a workaround (ConfigMap-sourced values remain in the bundle) and a principled defense (Secret-sourced values *should* stay out). The timestamp gap has neither — it is a straightforward loss of precision. Anyone re-proposing `exec` should argue it on that basis, and should account for the `pods/exec` permission ask and the loss of the "nothing executes in the router container" invariant as the price.

#### Why this is better, not merely equivalent

1. **It removes `pods/exec` from the required permissions.** That is a customer-visible reduction in a document platform teams approve line by line, and `exec` was the only thing requiring it.
2. **It makes the base spec entirely external.** With no `exec` collector, *nothing in the base spec executes inside the router container* — so "safe to run against a degraded router" becomes an invariant rather than a claim with a justified exception. That is a stronger property than any single signal.
3. **It is more reliable in exactly the situation the tool exists for.** Exec into a container that is OOM-killed, crash-looping, or unresponsive can fail or hang. Reading the pod spec goes to the API server and succeeds regardless of container health. The graph ref is therefore *more* likely to be present in an incident bundle, not less.
4. **It removes the arbitrary-single-pod semantics.** troubleshoot.sh's `exec` runs in one arbitrarily-selected pod when a selector matches several. The pod list covers every pod, so the data is fleet-wide by construction.
5. **It costs no extra collection.** `clusterResources` runs in every collection already. This is a read of data the bundle contains either way.

It also confirms the `APOLLO_KEY` guarantee from a third direction: in the same chart template, `APOLLO_KEY` is a `valueFrom.secretKeyRef`, so even a full pod-spec dump exposes only the Secret name and key, never the value.

#### The residual gap, by tier

Pod specs record env vars as *declared*; `exec` would read them as *resolved*. That difference only bites when a value is supplied indirectly — and it affects the two variables differently.

**`APOLLO_ROUTER_OFFICIAL_HELM_CHART` — nothing is lost, at any tier.** Its job is to identify the deployment type, and non-official-chart deployments do not set it at all, so **absence is the signal.** Pod-spec reading and `exec` report it identically: present and `"true"` means official chart, absent means not.

**`APOLLO_GRAPH_REF` — depends on how it is supplied**, which only varies outside the official chart, since the chart's plain-value rendering is verified above:

| How the customer supplies it | Pod-spec read | Recoverable from the bundle at all? |
| --- | --- | --- |
| Plain `value:` | Works | Yes |
| `envFrom` a ConfigMap | Shows the ConfigMap name only | **Yes** — `clusterResources` collects ConfigMaps with their `data`, so the value is in the bundle, just in a different file |
| `valueFrom` a Secret | Shows the reference only | No — and deliberately so, see below |
| Apollo Operator | Unknown — see below | Unknown |

**The Secret case is a reason to prefer this approach, not a cost of it.** A customer who puts their graph ref in a Secret has chosen to treat it as sensitive. `exec` reads the resolved environment and would pull that value into the bundle regardless of that choice; the pod-spec read respects it. Given that this tool's central promise is that it is safe to run, silently overriding a customer's own indirection is the wrong default.

Where the value is genuinely unavailable, `meta.json` records why via `expected_absences`. The cost is one bundle-*tagging* field — something support can ask for — not a diagnostic signal. It also lands on the tier that already operates with reduced signal by design, since raw-manifest deployments get no metrics either.

**A further argument against `exec` for exactly these customers:** `exec` depends on the container image shipping a binary it can run. A slim or distroless router image may not, and that failure would be silent in the same way as everything else here. Reading the pod spec has no such dependency. (Not verified against Apollo's published router images — noted as a consideration, not a finding.)

**Open, for the Operator tier:** confirm how the Operator sets `APOLLO_GRAPH_REF` — plain value or reference — and whether it sets a deployment-type variable of its own. Like the metrics port, this is an Apollo-defined convention and therefore answerable by inspection rather than a customer variable. Owned by `specs/deployment/v1/operator.md`.

**Test-matrix case this adds:** a raw-manifest deployment supplying the graph ref via `envFrom`, asserting that collection still succeeds, that the absence is recorded in `expected_absences`, and that the value is still findable in the collected ConfigMap data.

#### What this decision costs, in full

So the ledger is not one-sided. Dropping `exec` gives up:

1. **Resolution of indirected env vars**, per the table above — bounded, with a workaround for the ConfigMap case and a principled defense for the Secret case.
2. **A precise, timezone-explicit collection timestamp**, which `exec` would have provided for free. This is an unmitigated loss: the fallback is the bundle's directory name, which carries no timezone and disappears entirely if the customer overrides the output path. Recorded in `specs/collection/meta_json.md` → Collection time.

Both are accepted knowingly. Neither is a reason the decision was close — but if the base spec ever regains an `exec` collector for another reason, **the timestamp should be picked up in the same change**, since it is free at that point and there is no argument against it beyond the collector's own cost.

### Prometheus metrics: fixed port, tier-dependent

The `http` collector targets the metrics endpoint at a **fixed port confirmed from rendering the official Apollo router Helm chart** (`:9090/metrics`), not a port discovered from the customer's configuration. This port cannot be inferred from customer-supplied config the way the ConfigMap collectors above can fall back to labels — there is no equivalent discovery mechanism for an HTTP target, so the base spec relies on the official chart's known default.

For the **official Apollo router Helm chart**: this succeeds only when the customer has both enabled the Prometheus exporter *and* configured it to listen on an address reachable from outside the container. Two settings in `router.yaml` are load-bearing, not one:

- `telemetry.exporters.metrics.prometheus.enabled: true` — turns the exporter on.
- `telemetry.exporters.metrics.prometheus.listen` — the bind address. If the exporter is bound to loopback, an external scrape cannot reach it no matter what port the collector targets.

Confirmed from rendering the official chart: it is these two values inside the router configuration that actually turn metrics on in the rendered `configuration.yaml`. `serviceMonitor.enabled: true` at the chart level is a separate, independent switch — it renders a ServiceMonitor and exposes port `9090` on the Service, but does not by itself enable the exporter. A customer can have either one without the other.

If the exporter is off, or bound where the collector cannot reach it, the collector returns empty; the rest of the bundle is unaffected.

**Open:** the spec does not yet state whether the collector targets the Service or the pod directly. It matters here — the Service only carries the metrics port when `serviceMonitor.enabled: true`, so a customer who enabled the exporter but not the ServiceMonitor would get an empty section from a Service-targeted scrape and a populated one from a pod-targeted scrape.

For **raw-manifest and custom deployments**: the port cannot be inferred, so this collector returns empty rather than failing. This tier gets no metrics in v1 by design — the alternative, an optional `metricsPort` chart value, was considered and deferred; see `specs/deployment/v1/v1.md` → Rejected alternatives.

For the **Apollo Operator**: this must be stated as a fact, not hedged as a possibility. Unlike a customer's raw manifest, the Operator's metrics port is a convention Apollo defines, so whether the base spec's fixed `:9090` matches it is knowable by inspection rather than being a property of the customer's environment. "Returns empty if the port differs" would be an evasion rather than a specification: either the Operator uses `9090` and the collector works whenever the exporter is enabled, or it does not and the spec is wrong for the tier.

**Open — needs an answer, not a caveat:** confirm the Apollo Operator's metrics port and bind address, then state the outcome plainly here. Two paths follow from the answer:

- **If the Operator uses `:9090`** — the tier behaves exactly like the official chart, subject to the same exporter-enabled and bind-address conditions above, and this section says so.
- **If it differs** — one of two fixes, both cheap: the Operator populates the port when it writes the spec (it already populates every other targeting value, so this is consistent with how the tier works), or the base spec targets the Operator's port as a second known default. What is not acceptable is leaving the tier silently empty, since the zero-config tier is the one where an unexplained missing section is least diagnosable.

Until this is confirmed, treat metrics on the Operator tier as **unspecified** — not "probably empty" and not "probably works." Ownership sits with `specs/deployment/v1/operator.md`.

Subgraph health checks and OTel endpoint reachability were considered for the base spec and dropped for v1, for the same underlying reason: both would require an HTTP target (a subgraph URL, an OTel collector endpoint) that is customer-specific and has no chart-level default to fall back on, unlike the metrics port. Subgraph health is instead inferable from the router's own `apollo.router.operations.fetch*` metrics, which are already captured by this same Prometheus scrape when enabled.

### Redis health: not collected in v1 — decided

**The `redis` collector is not included in the v1 base spec.** Redis connectivity is not collected. The reasoning is recorded in full below, because the collector is an obvious thing to reach for and the reasons against it are not obvious.

#### Why it cannot be targeted

The collector needs a connection URI, and nothing can supply one safely:

- **No discovery of any kind.** Per the [collector documentation](https://troubleshoot.sh/docs/collect/redis/), `uri` is the one required field and must be supplied **inline**. A Kubernetes Secret can back the `tls` block (`cacert`, `clientCert`, `clientKey` via `tls.secret`), but there is no Secret or ConfigMap reference available for the URI itself.
- **No chart-level default to fall back on.** Confirmed by unpacking `router-2.10.5.tgz`: the chart contains **zero** references to Redis — no `redis` or `cache` values in `values.yaml`, no Redis subchart, no `dependencies` in `Chart.yaml`. The customer's Redis is infrastructure the router points at, not infrastructure the chart deploys, so rendering the chart makes nothing inferable. This is strictly worse than the metrics port, which at least has a documented chart default.

That places Redis health in the same category as subgraph health checks and OTel endpoint reachability, dropped above for the same reason, and it is treated consistently with them.

#### What is lost, precisely

The collector's output is one small JSON file per instance containing `isConnected`, `error`, and the Redis server `version` — connectivity and version, **not latency.** It is worth being precise about that, because a latency measurement would have been a stronger reason to want it.

What survives without it covers most of the diagnostic need:

- Redis errors and connection failures appear in the **router logs**.
- The Redis configuration block appears in the collected **`router.yaml`**, so support can see that Redis is configured and how.
- Router cache metrics are captured by the **Prometheus scrape** when enabled.

What is lost is an independent reachability check and the server version string.

#### Rejected alternatives

**Accept an optional `redisUri` chart value.** Rejected on structural grounds, not preference. A Redis URI commonly embeds credentials (`redis://user:password@host:6379`), and because the collector requires the URI inline, the chart would template that literal into the spec ConfigMap. That ConfigMap does not stay out of the bundle: [**`clusterResources` collects ConfigMaps with their full `data`**](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L2125) — it lists ConfigMaps per namespace and marshals the entire object, no key filtering — writing them to `cluster-resources/configmaps/<namespace>.json`. So an inline `redisUri` would place a live credential *inside the artifact the customer sends to support*, with only a redaction rule standing between it and disclosure.

That is the decisive objection. Depending on a redactor to strip a credential the tool itself introduced is exactly the posture ruled out for `APOLLO_KEY`: no redaction rule should be load-bearing for a secret. A collector that yields one boolean and a version string does not justify creating that dependency.

Two further points, in case the option is revisited:

- **A Secret reference is not a fix.** The collector accepts no Secret reference for the URI, and a chart value pointing at a Secret would simply have Helm read it and template the literal into the ConfigMap — same destination, same exposure.
- **Many customers could not supply it anyway.** Router configs frequently use `${env.REDIS_URL}`, which the `helm` and `configMap` collectors capture unresolved (config as written, not effective config). Those customers have no literal URI to hand the chart without extracting it from a Secret by hand.

**Infer the URI from the collected `router.yaml`.** Rejected — not possible with troubleshoot.sh as it stands, for two independent reasons: collectors do not take input from other collectors' output, and the spec is fully rendered before any collection runs. Even setting the mechanism aside, config-as-written may hold `${env.REDIS_URL}` rather than a usable address.

**Revisiting in v2 needs more than a Secret mechanism.** Even with credential handling solved, the collector connects from wherever collection *runs* — the invoking user's machine for `mode: local`, a Job pod for `mode: job` — not from the router. "Redis reachable from a laptop over a VPN" does not establish that the router pod can reach Redis, and it can mislead in both directions: a false alarm when the laptop cannot route to Redis but the router can, or false reassurance when the laptop can and the router cannot because of a NetworkPolicy or mTLS requirement. Router logs and cache metrics answer the question from the correct vantage point. Any future proposal should explain why the collector's vantage point is the right one, not only how the credential is protected.

### Namespace scoping is mandatory, not a default

`clusterResources` collects [**ConfigMaps with their full `data`**](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L2125), and if its `namespaces` field is unset it [enumerates **every namespace in the cluster**](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L132). An unscoped run therefore sweeps every ConfigMap in the cluster — unrelated teams' application config included — into a bundle the customer may share with Apollo.

The spec must set `namespaces: [<namespace>]` explicitly. Note the field name: `clusterResources` takes `namespaces`, a list, while `logs` and `configMap` take a singular `namespace` string. Omitting it on `clusterResources` fails in the opposite direction from the others — more data rather than less — so nothing about the resulting bundle looks wrong. See `specs/deployment/v1/v1.md` → Deployment tiers for how the chart wires the required value into both field shapes.

### Why `APOLLO_KEY` cannot appear in a bundle

The claim that `APOLLO_KEY` is never collected rests on mechanism rather than redaction, and both halves are verified:

- **Structural isolation.** Rendering the official chart confirms `APOLLO_KEY` is sourced from a separate Kubernetes Secret (`managedFederationApiKey`), not from the config ConfigMap the tool reads. A ConfigMap read cannot reach it.
- **No collector in the base spec reads Secret data.** `clusterResources` collects ConfigMaps but not Secrets as objects. Its only Secret access is `imagePullSecrets`, which filters to `kubernetes.io/dockerconfigjson` type and extracts the registry and username only — the source explicitly discards the password when splitting the decoded credential. No Secret `data` reaches the bundle.

This is why no redaction rule is load-bearing for `APOLLO_KEY`, and why any future collector that reads Secret data would be a change to this guarantee rather than an incremental addition.

### Memory and CPU information collected

Memory is the most nuanced collection area, because different levels of granularity require fundamentally different mechanisms. What the base spec collects is sufficient to **detect, confirm, and characterize** a memory problem: is memory growing, how fast, how close to the limit, and did the kernel already kill the container. It does not answer *which code path is leaking* — that needs jemalloc heap profiling via the router's diagnostics plugin, which is out of scope for v1.

| Signal | Source | Collected via | Resource consumed | What it tells you | Where | Notes |
| ----- | ----- | ----- | ----- | ----- | ----- | ----- |
| `memory.workingSetBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | How much memory k8s counts against the limit — the OOM kill threshold | k8s control plane → kubelet | Per node, per pod, per container. \[1\] |
| `memory.rssBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Physical RAM in use | k8s control plane → kubelet | \[1\] |
| `memory.usageBytes`, `memory.availableBytes` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Usage, and headroom remaining against the limit | k8s control plane → kubelet | \[1\] |
| `memory.pageFaults`, `memory.majorPageFaults` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Major faults indicate real paging pressure rather than growth alone | k8s control plane → kubelet | \[1\] |
| `cpu.usageNanoCores`, `cpu.usageCoreNanoSeconds` | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | CPU consumed by the router container | k8s control plane → kubelet | \[1\] |
| `cpu.psi`, `memory.psi` (pressure stall information) | kubelet Summary API | `nodeMetrics` collector | API server + kubelet CPU | Whether the container is *stalling* on CPU or memory — the contention question CPU throttling was meant to answer | k8s control plane → kubelet | Requires cgroup v2 and a recent kubelet; may be absent. Verify in the test matrix rather than assuming. |
| Configured `resources.limits` / `requests` | Pod spec | `clusterResources` collector | API server CPU | What the usage numbers above should be compared against | k8s control plane | Already collected as part of the pod list |
| OOM kill **occurrences** | Kubernetes events (`OOMKilling`, evictions) | `clusterResources` collector | API server CPU | That OOM kills happened, when, and how often — customers frequently do not know | k8s control plane | Per-occurrence record, retained as long as the cluster keeps events |
| OOM kill **last state** | Pod status `lastState.terminated.reason: OOMKilled`, `restartCount` | `clusterResources` collector | API server CPU | Whether the most recent restart was an OOM kill, and how many restarts have occurred | k8s control plane | Survives event expiry, unlike the row above — the two are complementary |
| Node `MemoryPressure` / `DiskPressure` conditions | Node objects | `clusterResources` collector | API server CPU | Whether the node itself is under pressure, distinguishing a router problem from a neighbour's | k8s control plane | |
| `process_resident_memory_bytes` | Router Prometheus endpoint | `http` collector | Network, router HTTP handler | Process-level RSS as the router sees it | Router network | Requires the Prometheus exporter enabled and reachably bound. Subject to the fixed-port caveat above. |
| `process_cpu_seconds_total` | Router Prometheus endpoint | `http` collector | Network, router HTTP handler | CPU time consumed by the router process | Router network | Same conditions as the row above |
| **Not collected:** `container_cpu_throttled_seconds_total` | cAdvisor `/metrics/cadvisor` | — | — | Whether the container is hitting its CPU cgroup limit | — | The metric exists in cAdvisor, but no troubleshoot.sh collector reaches that endpoint. `cpu.psi` above is the substitute. See below. |
| **Not collected:** `container_oom_events_total` | cAdvisor `/metrics/cadvisor` | — | — | A cumulative OOM-event counter | — | Same reason. The two OOM rows above cover the diagnostic need without it. |
| **Not collected:** heap dump `.prof` files | `experimental_diagnostics` plugin | — | — | Which code path / allocation site is holding memory | — | Requires `experimental_diagnostics` enabled and the `supported.rs:219` fix. Would also require in-container execution, which the base spec does not do. |
| **Not collected:** CPU flame graph / pprof | `pprof-rs` | — | — | Which code is consuming CPU | — | Requires router instrumentation; named future gap |

**\[1\]** The Summary API reports per node, per pod, and per container, so signal is correctly separated across every router pod in a fleet. This assumes one router process per container — the standard k8s pattern. Where multiple processes share a container, container-level figures are aggregates and cannot distinguish between them.

#### Why the Summary API and not cAdvisor's metrics endpoint

The kubelet exposes two endpoints carrying container-level resource data, and only one of them is reachable:

| Endpoint | Reached by | Contains |
| --- | --- | --- |
| `/api/v1/nodes/<node>/proxy/stats/summary` | The `nodeMetrics` collector | Per-container CPU and memory as JSON, plus PSI |
| `/api/v1/nodes/<node>/proxy/metrics/cadvisor` | **No troubleshoot.sh collector** | cAdvisor's Prometheus series, including throttling and OOM counters |

Sources, pinned so the line references stay valid:

| Claim | Evidence |
| --- | --- |
| `nodeMetrics` queries only the Summary API path | [`k8s_node_metrics.go#L18`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/k8s_node_metrics.go#L18) — `summaryUrlTemplate = "/api/v1/nodes/%s/proxy/stats/summary"`, the only endpoint the collector builds |
| The Summary API carries no throttling or OOM fields | [`stats/v1alpha1/types.go#L218`](https://github.com/kubernetes/kubelet/blob/v0.32.0/pkg/apis/stats/v1alpha1/types.go#L218) (`CPUStats`) and [`#L231`](https://github.com/kubernetes/kubelet/blob/v0.32.0/pkg/apis/stats/v1alpha1/types.go#L231) (`MemoryStats`) — zero occurrences of "throttl" or "oom" in the whole file |
| No collector named `containerMetrics` exists | [`collector_shared.go#L320`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/apis/troubleshoot/v1beta2/collector_shared.go#L320) — the `Collect` struct is the complete list of collectors the engine accepts |
| The `http` collector cannot authenticate to the API server | [`collector_shared.go#L185`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/apis/troubleshoot/v1beta2/collector_shared.go#L185) — `Get` accepts only static `headers`, so a bearer token would have to be a literal in the spec |
| `clusterResources` collects no metrics | [`cluster_resources.go`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go) — zero occurrences of "metric" in the file |
| `clusterResources` collects full pod objects, `env` included | [`cluster_resources.go#L473`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L473) — `pods()` marshals the whole `PodList` with no field filtering |
| …and full ConfigMaps, `data` included | [`cluster_resources.go#L2125`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go#L2125) — `configMaps()`, same pattern |

cAdvisor does carry the throttling and OOM counters — the constraint is that no troubleshoot.sh collector fetches that endpoint, and troubleshoot.sh is the engine we author against rather than one we extend.

References are pinned to troubleshoot.sh `v0.120.0` and `k8s.io/kubelet` `v0.32.0`. **Re-check them whenever the declared minimum troubleshoot.sh version changes** — a collector gaining a field is exactly the kind of change that would reopen a decision recorded here. See `specs/deployment/v1/v1.md` → Collection engine version.

**Why not just point the `http` collector at `/metrics/cadvisor`?** That path goes through the API server and requires authentication, and the `http` collector's `get` supports only static `headers`. A ServiceAccount bearer token would have to be templated into the spec ConfigMap — the same prohibition that rules out `redisUri`, and worse, since `clusterResources` collects that ConfigMap into the bundle. See `specs/deployment/v1/v1.md` → Chart values.

#### What this costs, and what it does not

Losing the two cAdvisor counters is narrower than it appears:

- **OOM detection is not weakened.** Events plus pod status give occurrence, timing, count, and whether the latest restart was an OOM kill. The counter would have been one number; this is a record.
- **CPU contention has a substitute, arguably a better one.** PSI measures whether the container is actually stalling, which is the question throttling was a proxy for. Its risk is availability, not usefulness — hence the test-matrix note.

#### RBAC: `nodes/proxy` exists for exactly one reason

`nodeMetrics` requires **`nodes/proxy` (get)** to reach the kubelet, plus **`nodes` (list)** to resolve node names when neither `nodeNames` nor `selector` is set. This is a heavier grant than a plain `nodes` read, and a security reviewer will treat it as such — proxying to the kubelet is a broader capability than reading node objects.

It is worth being precise about why it is requested, so a customer can decline it knowingly: **`nodes/proxy` buys pre-OOM memory trajectory for customers who have not enabled the Prometheus exporter.** That is the "is memory growing, how fast, how close to the limit" question, and for those customers there is no other source for it.

Declining it leaves intact: OOM kill occurrences and last state, restart counts, configured limits, node pressure conditions, and — when the exporter is enabled — process-level memory and CPU from the router itself. What is lost is container-level usage over time when Prometheus is off.

**`nodeMetrics` cannot be scoped to the router's nodes.** Its `selector` matches *nodes* by label, not pods, and the chart cannot enumerate node names at render time. So this collector inherently reads beyond the router's namespace, which is the underlying reason the permission is cluster-scoped rather than a quirk of how it is written. See `specs/deployment/v1/v1.md` → Permissions.

## Service mesh and proxy environments

Some customers run a service mesh or proxy (Istio, Linkerd, Envoy) as a sidecar alongside the router. Two things to note:

* The proxy itself can be the root cause of what looks like a router problem — a throttled or OOMing sidecar, mTLS failures, or Envoy circuit-breaking present as router latency or subgraph failures. To catch this, the `logs` collector captures all containers in the pod, not just the router, and the kubelet Summary API reports per-container figures, so a sidecar's own memory and CPU are visible alongside the router's.

* **The proxy can block a collector, and when it does the result is an empty section rather than an error.** A mesh enforcing strict mTLS intercepts inbound traffic to the pod, so a scrape originating outside the mesh — from the invoking user's machine in `mode: local`, or from a Job pod without a sidecar — can be rejected at the sidecar before the router ever sees it. Collection degrades gracefully, as designed: the run continues and the rest of the bundle is unaffected. But the failure is silent, so it needs to be recognizable.

  Only the **Prometheus metrics scrape** is meaningfully exposed to this. It is the one collector in the base spec that talks directly to a router port. Everything else reaches its data through the Kubernetes API server or the kubelet — `logs`, `clusterResources`, `nodeMetrics`, `configMap` — which a service mesh does not sit in front of.

  **The resulting ambiguity matters for triage.** An empty metrics section caused by mesh interception looks identical to one caused by the exporter being disabled, bound to loopback, or listening on a non-default port. The collected `router.yaml` is what separates them: if `telemetry.exporters.metrics.prometheus.enabled: true` is present in the config and the metrics section is still empty, the exporter was on and something prevented the scrape from landing — a mesh policy, the bind address, or the port. That inference only works because config and metrics are collected together, which is an argument for keeping them in the same spec.

Whether the `mode: job` pod joins the mesh is a deployment decision, not a collection one — it is specified in `specs/deployment/v1/v1.md` → Service mesh environments. The outcome relevant here: the Job runs *outside* the mesh, so a mesh-enforced scrape failure behaves the same way in both modes, and `meta.json` records it so the empty metrics section is attributable.
