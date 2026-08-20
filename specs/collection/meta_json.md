# `meta.json`

`meta.json` is the file that makes a bundle self-describing, within real limits. It records what the tool was configured to do, which is enough to make a healthy baseline bundle comparable against an incident bundle — but, as this file explains, it cannot reliably attribute *why* any individual section came up empty. This file specifies what it holds and, importantly, what it cannot.

## Who populates it

Not troubleshoot.sh — populating `meta.json` is entirely our responsibility.

For `mode: local` and `mode: job`, the `router-diagnostics` Helm chart's templates compute the content once, at `helm install` — not at collection time, and not per-collection. Every later `kubectl support-bundle --load-cluster-specs` against that installed spec reuses the same already-baked content.

The Apollo Operator tier is also on us to get right, but how the Operator actually populates equivalent content is specified in `specs/deployment/v1/operator.md`.

## How it is produced, and what that constrains

**troubleshoot.sh has no support-bundle-metadata feature.** The only thing it contributes is the **`data` collector** — a generic primitive that writes whatever literal string content we hand it to whatever path we name, with no awareness of what any other collector in the spec did or is doing:

```yaml
- data:
    name: meta.json
    data: |
      { … }
```

**The content is entirely ours to compute, and we compute it before collection ever runs.** The Helm chart's templates (or the Operator's spec-writing logic) already have `{{- if }}` conditionals over values they know at render time — `mode`, `redaction.includeSchema`, and so on — and bake the decided string into the `data` collector's literal `data:` field before `kubectl support-bundle` ever executes it. It lands at the root of the bundle, sibling to `version.yaml` and every other collector's output.

**This is not `metadata/user.json`.** That file comes from the `--metadata` flag and holds customer-supplied key-values typed at invocation — a different file with a different purpose, and it cannot carry anything specified below.

The consequence is the central design constraint here: **`meta.json` can only contain facts known when the spec is rendered** — by the Helm chart at install time, or by the Operator when it writes the spec. It cannot contain anything discovered during collection, which rules out fields like `router_version`, `graph_ref`, or a collection timestamp.

So `meta.json` does two things instead:

1. **States what the tool was configured to do**, from values known at render time.
2. **Documents, once, the fixed convention for where runtime facts actually live** in every bundle — it does not repeat that convention as data inside the file itself.

### Do not duplicate the engine version

Every bundle already contains **`version.yaml`**, written by the engine with the troubleshoot.sh version that produced it. The collection-engine-version requirement in `specs/deployment/v1/v1.md` is satisfied by that file — `meta.json` should reference it, not restate it. A second copy could disagree with the first, and the engine's own copy is the authoritative one.

## Contents

### Render-time facts

| Field | Source | Why it matters |
| --- | --- | --- |
| `spec_version` | Chart / Operator | Which version of the base spec produced this bundle. Bundles from different spec versions are not directly comparable. |
| `mode` | Chart value | `local` or `job`. Establishes where collection ran, which explains mesh-blocked and network-scoped results. Undefined for the Apollo Operator tier, which has no `mode` value — see [Who populates it](#who-populates-it) above. |
| `namespace` | Chart value | The namespace collection was scoped to — the counterpart to the cluster-wide-collection failure mode described in `base_spec.md`. |
| `redaction.include_schema` | Chart value | Whether the customer opted out of schema/SDL. Tells you one of the two possible reasons schema/SDL might be absent — the opt-out — but not the other (the customer never supplying `.Values.supergraphFile` to the *router's own* chart, a fact `router-diagnostics` has no visibility into at all). `true` here does not mean schema/SDL is actually present. |
| `sidecar_injection_disabled` | Chart, `mode: job` only | Records that the Job ran outside the mesh. Rules out one specific cause of an empty metrics section but does not, on its own, confirm a mesh issue exists — see `specs/collection/base_spec.md` → Service mesh and proxy environments. |
| `min_troubleshoot_version` | Spec | The declared floor from `specs/deployment/v1/v1.md` → Collection engine version. Compared against `version.yaml` by whoever reads the bundle. |

### Where runtime facts actually live

`meta.json` does not duplicate these values, and does not need to: their location is a fixed bundle-layout convention, true of every bundle this tool produces, documented once here rather than repeated as data inside every individual `meta.json`:

| Fact | Where it actually lives |
| --- | --- |
| Router version | `cluster-resources/pods/<namespace>.json` — container image tag |
| `APOLLO_GRAPH_REF` | `cluster-resources/pods/<namespace>.json` — `spec.containers[].env`, alongside the router version. See `specs/collection/base_spec.md` → Router env vars. |
| `APOLLO_ROUTER_OFFICIAL_HELM_CHART` | Same `spec.containers[].env` array as `APOLLO_GRAPH_REF` above. |
| Collection engine version | `version.yaml` |
| Collection time | The bundle's top-level directory name, `support-bundle-<timestamp>/` — see below |
| Whether more than one router release matched | File count under the `configMap` collector's output path — see below |

### Collection time

**`meta.json` does not carry a collection timestamp.** troubleshoot.sh names the bundle's top-level directory from the same timestamped basename it uses for the archive, so `support-bundle-2026-08-11T14_23_00/` survives even when a customer renames the `.tar.gz` before attaching it to a ticket — that directory name is the timestamp of record.

Two limits worth knowing before relying on it:

- **No timezone.** The value comes from the collecting machine's local clock. It establishes ordering and approximate time, not a point on a shared timeline — for precise correlation with an incident, use the timestamps inside the collected logs and metrics.
- **A custom output path removes it.** If the customer passes an output path, no timestamp appears anywhere in the naming; file modification times inside the archive are the fallback.

**Why not a `meta.json` field:** because `meta.json` is static, baked in at chart render time — a timestamp there would record when the chart was *installed*, not when collection ran, and a customer installs once but collects repeatedly for weeks afterward. A confidently wrong field is worse than an absent one.

### Multiple router releases in one namespace

**`meta.json` does not, and cannot, record whether the `configMap` collector's label selector matched more than one router release.** Per `specs/collection/base_spec.md` → `router.yaml` capture, targeting is by `app.kubernetes.io/name=router` alone — so a namespace holding more than one router release has every release's ConfigMap collected. Whether a second release exists isn't knowable when the chart renders (it could be added months after install), so this can't become a new render-time field for the same reason a collection timestamp can't be one.

**The fact is observable without a new field, though.** The `configMap` collector writes one file per match, named after the real ConfigMap it found — more than one file under that collector's output path *is* the signal that more than one release matched, visible to anyone who thinks to count.

## A complete example

Every field this file actually specifies, for a `mode: job` install:

```json
{
  "spec_version": "1",
  "mode": "job",
  "namespace": "production",
  "redaction": {
    "include_schema": true
  },
  "sidecar_injection_disabled": true,
  "min_troubleshoot_version": "0.120.0"
}
```

A `mode: local` install omits `sidecar_injection_disabled` entirely (it only applies to the Job path).

`meta.json` is only part of the picture, though — per [Where runtime facts actually live](#where-runtime-facts-actually-live) above, the rest of what a reader needs lives elsewhere in this same bundle.
