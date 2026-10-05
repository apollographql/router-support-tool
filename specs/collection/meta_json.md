# `meta.json`

`meta.json` is the file that makes a bundle self-describing. Populating `meta.json` is entirely our responsibility. It records what the tool was configured to do, which is enough to make a healthy baseline bundle comparable against an incident bundle — but, as this file explains, it cannot reliably attribute *why* any individual section came up empty. This file specifies what it holds and, importantly, what it cannot.

## How it is produced

**troubleshoot.sh has no metadata feature — only the `data` collector**, a generic primitive that writes whatever literal string we give it to whatever path we name, unaware of any other collector in the spec:

```yaml
- data:
    name: meta.json
    data: |
      { … }
```

We generate this content **before** collection runs. The consequence is the central design constraint here: **`meta.json` can only contain facts known when the spec is rendered** by the Helm chart at install time. It cannot contain anything discovered during collection such as `router_version`, `graph_ref`, or a collection timestamp.

## Contents

### Render-time facts

| Field | Source | Why it matters |
| --- | --- | --- |
| `version` | `.Chart.Version` | Which release of router-support-tool rendered this spec — the same `vX.Y.Z` published across the image, chart, and collect script. |
| `mode` | Chart value | `local` or `job`. Establishes where collection ran |
| `namespace` | Chart value | The namespace collection was scoped to |
| `sidecar_injection_disabled` | Chart, `mode: job` only | Records that the Job ran outside the mesh.|
| `troubleshoot_version` | Spec | The pinned version from `specs/deployment/v1/v1.md` → troubleshoot.sh support-bundle version. Compared against `version.yaml` by whoever reads the bundle. |

### Multiple router releases in one namespace

**`meta.json` can't record whether more than one router release matched** because its not known at render time. However, the `configMap` collector writes one file per match, so more than one file under its output path is the signal.

## A complete example

Every field this file actually specifies, for a `mode: job` install:

```json
{
  "version": "0.4.0",
  "mode": "job",
  "namespace": "production",
  "sidecar_injection_disabled": true,
  "troubleshoot_version": "0.134.1"
}
```

A `mode: local` install omits `sidecar_injection_disabled` (it only applies to the Job path).
