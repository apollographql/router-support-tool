# Collector naming conventions

Every collector in a spec is given a name. **For most collector types, troubleshoot.sh names the bundle's directory after it** — a collector called `router-metrics` produces `router-metrics/` inside the `.tar.gz`, holding the real file. That makes naming a compatibility surface for those types: rename one and every path in every future bundle changes, breaking bundle-to-bundle comparison across tool versions and any automation that reads a known path. **Treat a collector rename as a breaking change**, not a cosmetic edit.

**Some collector types are engine-fixed instead** — their output path is hardcoded by troubleshoot.sh regardless of what `name:` they're given. See [Engine-fixed collectors](#engine-fixed-collectors) below before assuming a rename moves a bundle path; four of the six collectors in the base spec fall into this category.

**One more is a hybrid, and it's the one most worth double-checking: `logs`.** Its chosen name controls a *symlink*, not the real file — see [Name-controlled via symlink: `logs`](#name-controlled-via-symlink-logs) below.

## The convention

**`<domain>-<signal>`** — a domain prefix, then what the data *is*. This applies to name-controlled collectors; it has no effect on engine-fixed ones.

- **Prefix by domain.** `router-` for signal about the router itself, `cluster-` for signal about the Kubernetes environment around it. A new domain gets a new prefix.
- **Name by signal, not by mechanism.** The name says what the data is, not how it was obtained. `router-metrics`, not `router-http-scrape`.
- **Lowercase kebab-case**, no underscores, no capitals. This matches troubleshoot.sh's own directory naming and avoids surprises across filesystems.

### Why mechanism must stay out of the name

**The mechanism can change without the signal changing.** If a signal moves from one collector type to another, a mechanism-based name becomes a lie while the data stays identical — and fixing the lie means a breaking rename.

### Disambiguating collectors that overlap

When two *name-controlled* collectors capture related signal, disambiguate by **what the data is**, not by which collector produced it — the distinction belongs in the name, not the mechanism. There's no live example of this in the base spec today (`router-runtime-logs` and `router-metrics`, the only two name-controlled collectors currently in use, don't overlap in signal). Apply the principle when one arises: extend it by adding a new, semantically-named entry to the table below, not by distinguishing new collectors by mechanism.

## Names for the base spec

Every collector gets a name, engine-fixed or not — for the engine-fixed rows below, the name is a display label only and has no effect on the bundle path. See [Engine-fixed collectors](#engine-fixed-collectors) for the actual paths.

| Signal | Collector | Name | Name controls bundle path? |
| --- | --- | --- | --- |
| Runtime logs, all containers in the pod | `logs` | `router-runtime-logs` | Only a symlink — see below |
| Prometheus metrics snapshot | `http` | `router-metrics` | Yes |
| Helm values layer of the config | `helm` | `router-config-values` | No — engine-fixed |
| Rendered `router.yaml` | `configMap` | `router-config-rendered` | No — engine-fixed |
| Node, pod, and container CPU/memory from the kubelet | `nodeMetrics` | `router-resource-usage` | No — engine-fixed |
| Pod status, router version, env vars, OOM events, node pressure | `clusterResources` | `cluster-resources` | No — engine-fixed |

## Name-controlled via symlink: `logs`

`logs` isn't a clean member of either category. Confirmed from [`logs.go` `savePodLogs`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/logs.go#L138): the real log content is written under the **engine-fixed** `cluster-resources/pods/logs/<namespace>/<pod>/<container>.log` — not under the collector's own name at all. The chosen `name:` (`router-runtime-logs`) only controls a **symlink** pointing at that real file, created because the collector's call site passes `createSymLinks: true`.

So renaming `router-runtime-logs` *is* still a breaking change — it moves the symlink's path, and any automation reading that path breaks exactly like it would for `http`. But the underlying data was never at risk of moving; it's pinned to the engine-fixed path regardless of what this collector is named. Two consequences:

- **A customer's extraction tooling that doesn't preserve symlinks can make `router-runtime-logs/` look empty or broken while the logs are actually intact** under `cluster-resources/pods/logs/`. Don't conclude logs weren't collected from an empty-looking `router-runtime-logs/` alone — check the engine-fixed path directly.
- The naming convention (domain-signal, no mechanism in the name) still fully applies to `logs` — it's a real, dereferenceable path a reader is meant to use, just not the only path to the same data.

See `specs/collection/output.md` for the full worked directory tree, including exactly how this symlink resolves.

## Engine-fixed collectors

`clusterResources`, `nodeMetrics`, `helm`, and `configMap` all write to paths hardcoded by the collection engine — confirmed by reading each collector's source at troubleshoot.sh `v0.120.0`. The `name:` field on these has no effect on where output lands; it only affects the display label shown during collection. Do not choose a name expecting it to control the bundle layout for any of these.

| Collector | Actual path | Source |
| --- | --- | --- |
| `clusterResources` | `cluster-resources/pods/<namespace>.json`, `cluster-resources/configmaps/<namespace>.json`, and similar, one file per resource type | [`cluster_resources.go`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/cluster_resources.go) — every `SaveResult` call uses the hardcoded `constants.CLUSTER_RESOURCES_DIR` |
| `nodeMetrics` | `node-metrics/<node>.json` | [`k8s_node_metrics.go#L60`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/k8s_node_metrics.go#L60) |
| `helm` | `helm/<namespace>.json` (or `helm/<namespace>/<releaseName>.json` if `releaseName` is set) | [`helm.go#L77-79`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/helm.go#L77) |
| `configMap` | `configmaps/<namespace>/<configmap-name>.json` (the real Kubernetes ConfigMap name, not the collector's `name:`) | [`configmap.go`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/configmap.go), `GetConfigMapFileName` |

This is why `router.yaml` capture (`specs/collection/base_spec.md` → `router.yaml` capture) never claims a chosen bundle path for the `helm`/`configMap` pair — there isn't one to choose. The values-layer-vs-rendered-config distinction between them is still real and worth keeping straight; it just isn't expressed through naming the way it would be for a name-controlled collector.

## Rules for adding a collector

- First, check whether the new collector's type is name-controlled or engine-fixed (see above). If engine-fixed, pick a reasonable `name:` for the display label, but don't expect it to affect the bundle layout or treat a later rename as breaking for path purposes.
- For name-controlled collectors: pick the name before writing the YAML, and check it against the table above for collisions and for consistency of domain prefix.
- If the obvious name contains a collector type (`exec`, `http`, `configmap`, `helm`), that is a signal the name is describing mechanism — rename it.
- If a new name-controlled collector overlaps an existing one's signal, disambiguate by what the data is, per [Disambiguating collectors that overlap](#disambiguating-collectors-that-overlap) above.
- **Avoid renaming an existing name-controlled collector.** It is a breaking change, not a routine edit — bundles produced before and after will not line up, silently breaking bundle-to-bundle comparison and any automation that reads a known path. Get the name right before shipping it rather than fixing it later. If a rename is genuinely unavoidable, treat it with the same scrutiny as a change to what is collected and call it out explicitly in the PR.
