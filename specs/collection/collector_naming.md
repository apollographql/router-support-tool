# Collector naming conventions

Every collector in a spec is given a name. For most collector types, troubleshoot.sh names the bundle's directory after it — a collector called `router-metrics` produces `router-metrics/` inside the `.tar.gz`, holding the real file. **Treat a collector rename as a breaking change**, not a cosmetic edit.

**Some collector types are engine-fixed instead** — their output path is hardcoded by troubleshoot.sh regardless of what `name:` they're given (see the table below).

## The convention

**`<domain>-<signal>`** — a domain prefix, then what the data *is*.

- **Prefix by domain.** `router-` for signal about the router itself, `cluster-` for signal about the Kubernetes environment around it. A new domain gets a new prefix.
- **Name by signal, not by mechanism.** The name says what the data is, not how it was obtained. `router-metrics`, not `router-http-scrape`. The mechanism can change without the signal changing.
- **Lowercase kebab-case**, no underscores, no capitals. This matches troubleshoot.sh's own directory naming and avoids surprises across filesystems.

**When two name-controlled collectors capture related signal, disambiguate by what the data is**, not by which collector produced it.

## Names for the base spec

Every collector gets a name, engine-fixed or not — for the engine-fixed rows below, the name is a display label only and has no effect on the bundle path.

| Name | Signal | Collector | Name controls bundle path? |
| --- | --- | --- | --- |
| `router-logs` | Runtime logs, all containers in the pod | `logs` | Only a symlink — see below |
| `router-metrics` | Prometheus metrics snapshot | `http` | Yes |
| `router-release-info` | Helm release metadata (name, chart, version, revision history) — never values | `helm` | No — engine-fixed |
| `router-config-rendered` | Rendered `router.yaml` | `configMap` | No — engine-fixed |
| `router-resource-usage` | Node, pod, and container CPU/memory from the kubelet | `nodeMetrics` | No — engine-fixed |
| `cluster-resources` | Pod status, router version, env vars, OOM events, node pressure | `clusterResources` | No — engine-fixed |

## Name-controlled via symlink: `logs`

This is a property of the `logs` collector type. Any collector of type `logs`, whatever name it's given, writes its real content to the fixed path `cluster-resources/pods/logs/<namespace>/<pod>/<container>.log` and only uses its `name:` to control a **symlink** pointing at that real file — troubleshoot.sh always creates this symlink for `logs` collectors, regardless of spec configuration. Renaming `router-logs` is still a breaking change since it moves the symlink.

**A customer's extraction tooling that doesn't preserve symlinks can make `router-logs/` look empty or broken while the logs are actually intact** under `cluster-resources/pods/logs/`. Don't conclude logs weren't collected from an empty-looking `router-logs/` alone — check the engine-fixed path directly.

See `specs/collection/output.md` for the full worked directory tree, including exactly how this symlink resolves.

## Rules for adding a collector

- First, check whether the new collector's type is name-controlled or engine-fixed. If engine-fixed, pick a reasonable `name:` for the display label, but don't expect it to affect the bundle layout or treat a later rename as breaking for path purposes.
- For name-controlled collectors: pick the name before writing the YAML, and check it against the table above for collisions and for consistency of domain prefix.
- If the obvious name contains a collector type (`exec`, `http`, `configmap`, `helm`), that is a signal the name is describing mechanism — rename it.
- If a new name-controlled collector overlaps an existing one's signal, disambiguate by what the data is, not by mechanism.
- **Avoid renaming an existing name-controlled collector.** It is a breaking change, not a routine edit. If a rename is genuinely unavoidable, treat it with the same scrutiny as a change to what is collected and call it out explicitly in the PR.
