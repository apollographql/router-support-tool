# Bundle Output Shape

What a produced bundle actually looks like once you extract it.

## The archive itself

`kubectl support-bundle` produces a single `support-bundle-<timestamp>.tar.gz`. Extracting it yields one top-level directory, named from the same timestamped basename as the archive. For example:

```
support-bundle-2026-08-11T14_23_00/
```

Everything below is relative to that one directory.

## Root-level files

Three files always land at the root, regardless of what the spec collects:

| File | Written by | Notes |
| --- | --- | --- |
| `version.yaml` | The engine itself, unconditionally | The troubleshoot.sh version that produced the bundle. |
| `analysis.json` | The engine, unconditionally | the support bundle runs analysis and writes this file on every collection, whether or not the spec declares any analyzers. |
| `meta.json` | Us, via the `data` collector | Not an engine file — see `specs/collection/meta_json.md` for what it holds and why. |

## A worked example

For a `mode: job` install in `production`:

```
support-bundle-2026-08-11T14_23_00/
├── version.yaml
├── analysis.json
├── meta.json
├── router-metrics-<pod-name>/
│   └── result.json
├── router-logs/
│   └── <router-pod-name>/
│       └── router.log -> ../../cluster-resources/pods/logs/production/<router-pod-name>/router.log
├── cluster-resources/
│   ├── pods/
│   │   ├── production.json
│   │   └── logs/production/<router-pod-name>/router.log         # the real file behind the symlink above
│   ├── configmaps/production.json
│   ├── events/production.json
│   ├── nodes.json
│   └── ...
├── node-metrics/
│   └── <node-name>.json
└── configmaps/
    └── production/
        └── <configmap-name>.json
```

Notes: 
- If more than one ConfigMap matched the label selector in `production`, the last entry becomes multiple files — one per ConfigMap, named after that ConfigMap's own Kubernetes name, not a Helm release (a raw-manifest or custom deployment has no Helm release of the router at all; this only coincides with a release name on the official Apollo router Helm chart).

- `cluster-resources/configmaps/production.json` is `clusterResources`'s full, unfiltered sweep of every ConfigMap in the namespace (schema is found here). `configmaps/production/<configmap-name>.json` is the dedicated `configMap` collector's own output, one file per matched ConfigMap.

## Bundle layout differs by mode for `router-metrics`

The example above is `mode: job`, where `router-metrics` is one `http` collector per pod (`specs/collection/base_spec.md` → Per-pod metrics collection). troubleshoot.sh writes each `http` collector's result at a top-level `<collector-name>/result.json`, so pod `router-7f8`, for example, lands at:

```
router-metrics-router-7f8/
└── result.json
```

**`mode: local` is a `hostCollectors.run` collector instead, and troubleshoot.sh nests a host run collector's `outputDir` differently** — under `host-collectors/run-host/<collectorName>/`, not at the top level. This collector's `collectorName` is `router-metrics` and its `outputDir` is `pods`. The same per-pod metrics data lands at:

```
host-collectors/run-host/
└── router-metrics/
    └── pods/
        ├── router-7f8.txt
        └── router-9ad.txt
```
