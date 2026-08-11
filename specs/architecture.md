# Router Support Tool — Architecture

The Router Support Tool collects a sanitized, point-in-time snapshot of Apollo Router and Kubernetes cluster state without requiring a router restart.

The tool is built on [troubleshoot.sh](https://troubleshoot.sh), which provides the collection engine: the collectors themselves, the redaction pipeline, and assembly of collector output into a bundle. **v1 uses their collectors and redactors; analyzers are deliberately out of scope** — see `specs/versions/v1.md` → Use of troubleshoot.sh for what we use, what we do not, and links into their documentation.

**We define what runs through that engine** — which collectors, with which parameters, and which redaction rules — **and we own everything around it**: the Helm chart, the published spec artifact, and the Job image.

If a task seems to call for writing collection machinery, check whether troubleshoot.sh already provides it. The following is ours:

- How the spec reaches a cluster
- How collection is triggered
- How a bundle is stored
- How redaction preferences are exposed to the customer

See `specs/user_experience.md` for a detailed description of the user experience.

## The three layers

The architecture separates three concerns that vary independently of one another:

| Layer | What varies |
| --- | --- |
| **Collection** | What data is collected, and how it is sanitized |
| **Trigger** | What causes a collection to happen |
| **Storage** | Where the resulting bundle lands |

The boundaries are drawn so that a change in one layer does not require changes in the others. Adding a new trigger does not touch the spec. Adding a new storage target does not touch collectors. Adding a new spec does not touch the watcher (for threshold based triggers).

Deployment — where the collection process actually runs, and what permissions it needs is deliberately *not* a layer. See [Deployment model](#deployment-model) below.

```
┌─────────────────────────────────────────────────┐
│  TRIGGER                                        │
│  What causes collection to happen               │
│  on-demand · scheduled · threshold              │
└────────────────────┬────────────────────────────┘
                     │ invokes
                     ▼
┌─────────────────────────────────────────────────┐
│  COLLECTION                                     │
│  What data is collected and how it's sanitized  │
│  SupportBundle spec + custom redactors          │
└────────────────────┬────────────────────────────┘
                     │ produces a redacted bundle
                     ▼
┌─────────────────────────────────────────────────┐
│  STORAGE                                        │
│  Where the bundle lands                         │
│  local disk · object storage                    │
└─────────────────────────────────────────────────┘
```

### Why these boundaries?

The layer boundaries are drawn to make each anticipated extension touch exactly one layer:

| Change | Touches |
| --- | --- |
| Add a new `enhanced-memory` spec | Collection only |
| Add threshold-triggered collection | Trigger only |
| Add leading-indicator metrics to threshold rules | Trigger only — the watcher takes a metric name as config so a new metric is a config addition |
| Add S3/GCS bundle storage | Storage only |
| Deploy the tool via Ground Control's ClusterManager | Deployment model only |
| Support a new deployment tier | Deployment model only |

Redaction and execution location are deliberately *not* layers — the first because it does not vary independently of collection, the second because it is a choice about where existing functions run rather than a function of its own.

---

## Collection layer

**What varies:** which signals are gathered, and which redactors are applied.

A collection is defined by a [troubleshoot.sh SupportBundle spec](https://troubleshoot.sh/docs/support-bundle/collecting) — a YAML file declaring which collectors to run, against which targets, with which parameters, plus the redactors to apply before packaging.

### Specs

v1 ships **one spec** — a single base spec definition, authored once, and the only collection artifact v1 produces. Deployment tiers differ only in who populates its targeting values (the Apollo Operator, or the Helm chart from customer-supplied values); they do not each get their own spec. See `specs/deployment/v1/v1.md` for why a per-tier spec was rejected.

Additional specs are introduced in later milestones as new collection capabilities are added.

Shipping capabilities as separate specs, rather than growing a single spec, is motivated by a concrete safety constraint: some collectors (notably `exec`-based ones) run commands inside the router's existing container and consume from its cgroup allocation rather than a separate budget. **The v1 base spec contains none of these** — it runs entirely against the API server, the kubelet, and external endpoints. Heavier collection operations therefore warrant their own spec, with independent controls over when they run.

For example, a future `enhanced-memory` spec might use the router's diagnostics plugin to profile memory via jemalloc. Because triggering a heap dump above certain memory thresholds risks worsening the pressure it is trying to diagnose, that spec ships with its own schedule and threshold rules — independent of the base spec's cadence.

Collection degrades gracefully. A collector whose target does not exist — Prometheus not enabled, no matching ConfigMap, a Helm release the `helm` collector cannot find — returns empty rather than failing the run. `meta.json` records which collectors ran, so an empty section is explainable rather than mysterious.

#### base spec

**All** signal is gathered externally — via the k8s API, the kubelet's Summary API, or direct HTTP calls to the router's externally reachable endpoints. Nothing in the base spec executes inside the router container, so none of its collection draws on the router's cgroup allocation. It is safe to run at any time, including against a degraded router.

This is an invariant to preserve, not an incidental property of the current collector set. It became absolute when the last in-container collector was removed — the `exec` read of `APOLLO_GRAPH_REF` and `APOLLO_ROUTER_OFFICIAL_HELM_CHART`, now read from the pod spec instead (see `specs/collection/base_spec.md` → Router env vars). A collector that needs to run inside the container does not belong in the base spec; it belongs in a separate spec with its own trigger and threshold controls, for the reasons above. See `specs/collection/base_spec.md` for more information on what the base spec collects, including collector-level targeting details and why some previously-considered collectors (subgraph health checks, OTel reachability) were dropped.

| Signal | Collector |
| --- | --- |
| Pod status, restart counts, resource limits | `clusterResources` |
| Router version (container image tag) | `clusterResources` |
| Runtime logs (all containers in the pod) | `logs` |
| Container CPU and memory metrics, PSI | `nodeMetrics` (kubelet Summary API) |
| Prometheus metrics snapshot | `http` |
| `router.yaml` configuration | `helm` + `configMap` |
| `APOLLO_GRAPH_REF`, `APOLLO_ROUTER_OFFICIAL_HELM_CHART` (from the pod spec) | `clusterResources` |

Redis health was considered and is **not** collected in v1: the `redis` collector requires an inline connection URI, which no deployment tier can supply without placing a credential in the spec ConfigMap — and that ConfigMap is itself collected into the bundle. Redis remains visible through router logs and the collected `router.yaml`. See `specs/collection/base_spec.md`.

Two of these collectors have deployment-tier-dependent behavior worth flagging here, with detail in `specs/collection/base_spec.md`:

- **`router.yaml` configuration** — both `helm` and `configMap` run unconditionally; whichever matches the customer's deployment populates, the other returns empty. For the official Apollo Helm chart, the `configMap` collector targets by the chart's standard label rather than needing a release name.
- **Prometheus metrics snapshot** — targets a fixed port known from the official Apollo Helm chart, and requires the exporter to be both enabled and bound reachably. For raw-manifest and custom deployments the port cannot be inferred, so this returns empty by design. For the Apollo Operator the port is an Apollo-defined convention and therefore a fact to be confirmed rather than a variable to hedge — see `specs/collection/base_spec.md`.

### Redaction

Redaction is **part of this layer, not a separate one.** It does not vary independently of collection: redactors are defined in the same spec YAML, ship in the same artifact, version together, and are authored alongside the collectors they protect. troubleshoot.sh treats redaction as a phase of the collection pipeline — collect, redact, package — not a separable concern.

Redaction runs after all collectors complete and before the bundle is packaged, so it applies to the complete collected data rather than per-collector, and the customer can inspect the redacted output before sharing.

Two categories:

- **Built-in redactors** (troubleshoot.sh, no Apollo work) — passwords and API tokens, AWS credentials, connection strings, IP addresses, bearer tokens and Authorization headers.
- **Custom redactors** (authored by Apollo) — JWT and auth config, header values in config (keys preserved, values stripped), operation bodies in logs, subgraph URLs, graph schema/SDL.

One of these — schema/SDL — is customer-configurable (included by default, opt-out available); the mechanism for setting that preference is a chart value, described in `specs/deployment/`. Everything else is fixed with no customer configuration.

`APOLLO_KEY` is never collected in the first place. It is structurally isolated in a separate Kubernetes Secret from the ConfigMap the tool reads, so no redaction rule is load-bearing for it.

See `specs/collection/data_sanitization/` for more details on redaction.

---

## Trigger layer

What causes collection to occur.

Triggers are independent mechanisms that invoke a collection spec. Each can be added without modifying the spec it invokes.

| Trigger | Milestone | Mechanism |
| --- | --- | --- |
| On-demand (flare) | v1 | User invokes collection directly |
| Scheduled base collection | v2 | CronJob on a configurable interval (default 15m) |
| Threshold-triggered | v2 | Watcher Deployment polling metrics against threshold rules |
| Scheduled additional specs | v3 | CronJob on an independent cadence per spec |

See `specs/trigger/` for more information.

### On-demand (v1)

The user invokes a collection. No standing infrastructure is required.

### Scheduled (v2)

A CronJob invoking the base spec on a configurable interval, building a continuous timeline of lightweight signal. The timeline is the primary tool for diagnosing slow degradation — memory creeping up over hours, gradual error rate increase — because it enables "good router vs. bad router" comparison.

Truly continuous collection was considered and deliberately excluded. Scheduled collection at an interval provides the diagnostic baseline value without the standing resource overhead, and discrete bundles are easier for customers to inspect and audit before sharing.

### Threshold-triggered (v2)

A small watcher Deployment polls the k8s metrics API or Prometheus on a configurable interval and fires or suppresses collection based on threshold rules.

The watcher is both trigger and circuit breaker. A two-tier model applies:

- **Early warning** (e.g. 75–85%) — fires collection, capturing router state before conditions worsen.
- **Danger zone** (e.g. 90%+) — *suppresses* collection regardless of other rules, preventing the tool from worsening a degraded situation.

Threshold rules are metric-agnostic by design. Memory and CPU are the metrics available today, but they are trailing indicators — by the time memory is climbing, the causal event has already happened. Leading indicators such as queue depth and concurrency saturation would fire earlier and point at cause rather than symptom. Because rules are metric-agnostic, adding those later is a configuration change, not a redesign.

> **Note:** the v2 scheduled/threshold chart has not yet gone through the same parameter-passing and deployment-tier analysis as the v1 collection chart described in `specs/deployment/v1/v1.md`. Whether it needs the same tiered targeting approach is still open.

---

## Storage layer

**What varies:** where the bundle lands after collection.

The same spec produces the same bundle regardless of destination. A change in storage target does not touch a collector, and a change in collection does not touch storage configuration — which is what makes this a layer rather than a detail of collection.

One invariant holds across every storage option: **bundles are never pushed to Apollo infrastructure.** Storage is customer-owned and customer-controlled. Apollo has access only when a customer explicitly shares a bundle as part of a support engagement.

Storage is not something later milestones add to the architecture, it is a dimension that has always been present. Local invocation (`mode: local`) has a storage answer (the invoking user's local disk), it is simply the degenerate case requiring no design. Any unattended collection, the restricted-access Job (`mode: job`) as well as v2's scheduled and threshold-triggered collection, for example, is what forces the question to be answered explicitly, because no user is present to receive the bundle.

Storage options, their tradeoffs, and the reasoning behind the current choice are specified in `specs/storage/`.

---

## Deployment model

Where the collection process runs — from a local machine, or in-cluster as a Job or CronJob — is a **deployment concern, not an architectural layer.**

The distinction matters. Each layer above corresponds to a function the system performs, and each introduces logic that does not exist elsewhere: the trigger layer adds metric polling and threshold evaluation, the storage layer adds auth, retry, and retention. Execution location adds no new capability. Running `kubectl support-bundle` from a container instead of a laptop is the same function relocated, using a ServiceAccount instead of a kubeconfig.

The test: the system's behavior can be fully described without reference to execution location. *"On threshold crossing, collect the base spec, write to object storage"* is complete. Where the process happens to run is an implementation detail of that sentence — unlike storage, where *"the bundle goes somewhere"* leaves a genuine open question.

Deployment concerns include:

- **Execution location** — local plugin vs. in-cluster Job or CronJob
- **RBAC** — the user's own kubeconfig vs. a namespace-scoped ServiceAccount
- **Cluster footprint** — ranges from nothing (pure local invocation) to a persistent ConfigMap (chart-based invocation) to standing workloads (scheduled/threshold collection), depending on execution location
- **Deployment tier** — how the customer deployed the router, which determines how much the tool can infer versus what the customer must supply

Which tiers are supported, what each requires from the customer, and how execution location and deployment tier are actually implemented (the `router-diagnostics` chart and its values) is specified per version rather than here — see `specs/deployment/v1/v1.md` for v1's answer to all of the above.

Future delivery mechanisms belong here too. Ground Control's ClusterManager, for instance, is a way of delivering and managing these components in-cluster. This is another deployment mechanism, not a new layer.

See the `specs/deployment/` directory for more information.
