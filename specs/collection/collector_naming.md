# Collector naming conventions

Every collector in a spec is given a name, and **troubleshoot.sh names the bundle's directories after it.** A collector called `router-runtime-logs` produces `router-runtime-logs/` inside the `.tar.gz`. The name is therefore not a label for our own benefit — it is the bundle's directory structure, which is the first thing a support engineer navigates and the thing any tooling reading a bundle depends on.

That makes naming a compatibility surface. Rename a collector and every path in every future bundle changes, breaking bundle-to-bundle comparison across tool versions and any automation that reads a known path. **Treat a collector rename as a breaking change**, not a cosmetic edit.

## The convention

**`<domain>-<signal>`** — a domain prefix, then what the data *is*.

- **Prefix by domain.** `router-` for signal about the router itself, `cluster-` for signal about the Kubernetes environment around it. A new domain gets a new prefix.
- **Name by signal, not by mechanism.** The name says what the data is, not how it was obtained. `router-config`, not `router-configmap-read`. `router-metrics`, not `router-http-scrape`.
- **Lowercase kebab-case**, no underscores, no capitals. This matches troubleshoot.sh's own directory naming and avoids surprises across filesystems.

### Why mechanism must stay out of the name

Two reasons, both concrete:

1. **The mechanism can change without the signal changing.** If `router.yaml` capture moves from a ConfigMap read to something else, a name like `router-configmap-config` becomes a lie while the data stays identical — and fixing the lie means a breaking rename.
2. **One signal already has two mechanisms.** `helm` and `configMap` both run to capture configuration, and whichever matches the customer's deployment populates. A mechanism-based name would make the *same* signal appear under different directories depending on the customer's deployment tier, which defeats the purpose of shipping one spec for all tiers.

### Disambiguating collectors that overlap

When two collectors capture related signal, disambiguate by **what the data is**, not by which collector produced it. For the configuration pair, the two outputs are genuinely different things — one is the Helm values layer, the other is the rendered config — so the distinction belongs in the name:

| Collector | Name | What the data is |
| --- | --- | --- |
| `helm` (`collectValues: true`) | `router-config-values` | The Helm values layer, which may differ from the rendered config |
| `configMap` | `router-config-rendered` | The rendered `configuration.yaml` as written to the ConfigMap |

This reads as a semantic distinction rather than an implementation detail, and it stays true even if either mechanism is replaced.

## Names for the v1 base spec

| Signal | Collector | Name |
| --- | --- | --- |
| Runtime logs, all containers in the pod | `logs` | `router-runtime-logs` |
| Prometheus metrics snapshot | `http` | `router-metrics` |
| Helm values layer of the config | `helm` | `router-config-values` |
| Rendered `router.yaml` | `configMap` | `router-config-rendered` |
| Node, pod, and container CPU/memory from the kubelet | `nodeMetrics` | *(engine-fixed: `node-metrics/<node>.json`)* |

The router env vars (`APOLLO_GRAPH_REF`, `APOLLO_ROUTER_OFFICIAL_HELM_CHART`) have no entry of their own: they arrive inside the pod objects `clusterResources` collects, so they land at that collector's engine-fixed path rather than one we name. See `specs/collection/base_spec.md` → Router env vars.

**`clusterResources` is the exception.** Its output paths are fixed by the collection engine — `cluster-resources/pods/…`, `cluster-resources/configmaps/…` — and are not derived from a name we choose. The convention applies to collectors whose output directory we control; where the engine dictates the path, the engine wins and there is nothing to name.

## Rules for adding a collector

- Pick the name before writing the YAML, and check it against the table above for collisions and for consistency of domain prefix.
- If the obvious name contains a collector type (`exec`, `http`, `configmap`, `helm`), that is a signal the name is describing mechanism — rename it.
- If a new collector overlaps an existing one's signal, extend the pair pattern above rather than distinguishing by mechanism.
- A rename to an existing collector needs the same scrutiny as a change to what is collected, because bundles produced before and after will not line up. Call it out explicitly in the PR.
