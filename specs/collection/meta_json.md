# `meta.json`

`meta.json` is the file that makes a bundle self-describing. Populating `meta.json` is entirely our responsibility. It records what the tool was configured to do, which is enough to make a healthy baseline bundle comparable against an incident bundle — but, as this file explains, it cannot reliably attribute *why* any individual section came up empty. This file specifies what it holds and, importantly, what it cannot.

Note: **This is not `metadata/user.json`.** That file comes from the `--metadata` flag and holds customer-supplied key-values typed at invocation.

## How it is produced

**troubleshoot.sh has no metadata feature — only the `data` collector**, a generic primitive that writes whatever literal string we give it to whatever path we name, unaware of any other collector in the spec:

```yaml
- data:
    name: meta.json
    data: |
      { … }
```

We generate this content **before** collection runs. The consequence is the central design constraint here: **`meta.json` can only contain facts known when the spec is rendered** — by the Helm chart at install time, or by the Operator when it writes the spec. It cannot contain anything discovered during collection such as `router_version`, `graph_ref`, or a collection timestamp.

## Contents

### Render-time facts

| Field | Source | Why it matters |
| --- | --- | --- |
| `spec_version` | Chart / Operator | Which version of the spec produced this bundle. |
| `mode` | Chart value | `local` or `job`. Establishes where collection ran |
| `namespace` | Chart value | The namespace collection was scoped to |
| `sidecar_injection_disabled` | Chart, `mode: job` only | Records that the Job ran outside the mesh.|
| `min_troubleshoot_version` | Spec | The declared floor from `specs/deployment/v1/v1.md` → Collection engine version. Compared against `version.yaml` by whoever reads the bundle. |

### Multiple router releases in one namespace

**`meta.json` can't record whether more than one router release matched** because its not known at render time. However, the `configMap` collector writes one file per match, so more than one file under its output path is the signal.

## A complete example

Every field this file actually specifies, for a `mode: job` install:

```json
{
  "spec_version": "1",
  "mode": "job",
  "namespace": "production",
  "sidecar_injection_disabled": true,
  "min_troubleshoot_version": "0.120.0"
}
```

A `mode: local` install omits `sidecar_injection_disabled` (it only applies to the Job path).
