# `meta.json`

`meta.json` is the file that makes a bundle self-describing. Several requirements across these specs lean on it — an empty collector section must be explainable, a healthy baseline bundle must be comparable against an incident bundle, and support must be able to tell what a bundle *should* have contained. This file specifies what it holds and, importantly, what it cannot.

## How it is produced, and what that constrains

troubleshoot.sh does not assemble a metadata file for us. It is written by the **`data` collector**, which writes static inline content to a chosen path in the bundle:

```yaml
- data:
    name: meta.json
    data: |
      { … }
```

**This is not `metadata/user.json`.** That file comes from the `--metadata` flag and holds customer-supplied key-values typed at invocation. It is a different file with a different purpose, and it cannot carry anything specified below, since its content depends on what the invoking user chooses to type.

The consequence is the central design constraint here: **`meta.json` can only contain facts known when the spec is rendered** — by the Helm chart at install time, or by the Operator when it writes the spec. It cannot contain anything discovered during collection, because the content is a literal baked into the spec before any collector runs.

This rules out the shape earlier design material assumed, where `meta.json` carried `router_version`, `graph_ref`, and a collection timestamp. Those are runtime facts. Nothing in the `mode: local` path assembles a file after collection completes, so they cannot be written there.

So `meta.json` does two things instead:

1. **States what the tool was configured to do**, from values known at render time.
2. **Points at where runtime facts live** in the bundle, rather than duplicating them.

### Do not duplicate the engine version

Every bundle already contains **`version.yaml`**, written by the engine, holding the troubleshoot.sh version that produced it (confirmed in `pkg/supportbundle/supportbundle.go`, using `constants.VERSION_FILENAME`). The collection-engine-version requirement in `specs/deployment/v1/v1.md` is satisfied by that file — `meta.json` should reference it, not restate it. A second copy could disagree with the first, and the engine's own copy is the authoritative one.

## Contents

### Render-time facts

| Field | Source | Why it matters |
| --- | --- | --- |
| `spec_version` | Chart / Operator | Which version of the base spec produced this bundle. Bundles from different spec versions are not directly comparable. |
| `deployment_tier` | Chart value / Operator | `operator`, `official_helm_chart`, or `custom`. Determines which collectors were expected to populate at all. |
| `mode` | Chart value | `local` or `job`. Establishes where collection ran, which explains mesh-blocked and network-scoped results. |
| `namespace` | Chart value | The namespace collection was scoped to — the counterpart to the cluster-wide-collection failure mode described in `base_spec.md`. |
| `redaction.include_schema` | Chart value | Whether schema/SDL was retained. Without this, an absent schema is ambiguous between "opted out" and "not collected". |
| `sidecar_injection_disabled` | Chart, `mode: job` only | Records that the Job ran outside the mesh, which is the expected cause of an empty metrics section in a mesh cluster. |
| `min_troubleshoot_version` | Spec | The declared floor from `specs/deployment/v1/v1.md` → Collection engine version. Compared against `version.yaml` by whoever reads the bundle. |

### Expected absences

**This is the highest-value part of the file.** `specs/collection/base_spec.md` and the testing rules in `CLAUDE.md` both require that an empty section be attributable to a named reason rather than assumed to be graceful degradation working. The chart knows most of those reasons at render time, so it should write them down rather than leaving a reader to infer them:

```json
"expected_absences": [
  { "path": "router-metrics",          "reason": "deployment_tier=custom: metrics port cannot be inferred" },
  { "path": "router-config-values",    "reason": "configMap collector is authoritative for this tier; helm collector expected empty" },
  { "path": "redis",                   "reason": "redis collector not included in v1" }
]
```

An empty section listed here is expected. **An empty section not listed here is a defect** — which is precisely the distinction that is otherwise impossible to draw from the bundle alone, and the one the verification rules insist on.

### Pointers to runtime facts

Rather than duplicating values it cannot see, `meta.json` records where they are:

| Fact | Where it actually lives |
| --- | --- |
| Router version | `cluster-resources/pods/<namespace>.json` — container image tag |
| `APOLLO_GRAPH_REF` | `router-deployment-env/` |
| Collection engine version | `version.yaml` |
| Collection time | The bundle's top-level directory name, `support-bundle-<timestamp>/` — see below |

### Collection time

**`meta.json` does not carry a collection timestamp.** A usable one is already inside the bundle, in a place that survives more handling than the archive filename does.

troubleshoot.sh builds the bundle in a directory named from the same timestamped basename it uses for the archive (`pkg/supportbundle/supportbundle.go` — `basename = fmt.Sprintf("support-bundle-%s", time.Now().Format("2006-01-02T15_04_05"))`, and the bundle directory is that basename with the extension stripped). So the top-level directory *inside* the `.tar.gz` is `support-bundle-2026-08-11T14_23_00/`. Renaming the archive — which customers do routinely when attaching it to a ticket — does not lose it.

Two limits, both worth knowing before relying on it:

- **No timezone.** The format has no offset, and the value comes from `time.Now()` on whatever machine ran collection. It establishes ordering and approximate time, not a point on a shared timeline. For precise correlation with an incident, use the timestamps inside the collected logs and metrics, which carry their own absolute times.
- **A custom output path removes it.** If the customer passes an output path, that basename replaces the timestamped default and no timestamp appears anywhere in the naming. File modification times inside the archive are the fallback.

#### Why the timestamp is not a `meta.json` field

Not because of any mode difference — because **`meta.json` is static.** Its content is baked in when the chart renders, so a timestamp there would record when the chart was *installed*, not when collection ran. A customer installs once and collects repeatedly for weeks afterwards, so that field would be confidently wrong rather than merely imprecise, which is worse than absent.

Getting a real collection-time value therefore requires a collector that runs at collection time, not a field in a static file.

Both alternatives that would produce a precise, timezone-explicit timestamp are ruled out by decisions taken elsewhere, so **the directory name is the timestamp of record.**

**Unavailable, not rejected on its merits: `date -u` appended to an `exec` collector's command.** This is the option we would want — free if we were already exec'ing, UTC-explicit, and read from the router container's own clock, the same clock that stamps the router's logs. It is unavailable only because `specs/collection/base_spec.md` → Router env vars removed the `exec` collector entirely, on grounds that had nothing to do with timestamps. That decision records losing this as one of its two acknowledged costs.

The distinction matters for anyone revisiting either decision: nothing is wrong with this mechanism. Reintroducing `exec` solely for a timestamp would be a bad trade — it reinstates the `pods/exec` permission ask and gives up the "nothing executes in the router container" invariant for a convenience — but **if an `exec` collector ever returns for an independent reason, this should be added in the same change.** At that point it is free.

**Rejected: a pod-creating collector that runs `date`.** It would work in both modes without depending on exec, but it requires permission to create pods. Trading a read-only RBAC posture for a timestamp is a bad deal, and the permissions section of `specs/deployment/v1/v1.md` is a document customers approve — every entry in it has to earn its place.

If precise, zone-aware timing is ever needed, the honest answer is that the collected logs and metrics already carry it, at higher resolution than a single collection-start timestamp would.

## Fields deferred to v2

These belong to the trigger layer and have no meaning while v1 is on-demand only. Recorded here so the schema is extended deliberately rather than reinvented:

- `trigger` — `flare` \| `scheduled` \| `threshold`
- `trigger_detail` — the metric, its value, and the threshold crossed
- `specs_collected` — a list, once more than one spec exists
- `min_router_version` — for specs that require a minimum router version, such as a future `enhanced-memory` spec depending on the diagnostics plugin. Collection degrades gracefully below it: dependent collectors return empty while the rest of the bundle completes.

## Open questions

- **Whether the Operator writes the same fields.** It renders the spec itself, so it must populate `meta.json` equivalently or Operator bundles will be less explainable than every other tier's. Owned by `specs/deployment/v1/operator.md`.
