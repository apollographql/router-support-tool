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
├── host-collectors/
│   └── run-host/
│       ├── router-metrics.txt                 # the collector's own output, including why any metrics are missing
│       ├── router-metrics-stderr.txt          # the script's stderr, only present if it wrote any
│       └── router-metrics/
│           └── pods/
│               └── <router-pod-name>.txt
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

## `router-metrics` layout

`router-metrics` is a `hostCollectors.run` collector (`specs/collection/base_spec.md` → Per-pod metrics collection). troubleshoot.sh nests a host run collector's `outputDir` under `host-collectors/run-host/<collectorName>/`. This collector's `collectorName` is `router-metrics` and its `outputDir` is `pods`, so pods `router-7f8` and `router-9ad`, for example, land at:

```
host-collectors/run-host/
└── router-metrics/
    └── pods/
        ├── router-7f8.txt
        └── router-9ad.txt
```

Each file is that pod's raw `/metrics` response, in Prometheus text format. A pod with no file was not scraped; the collector's own output carries the line saying why (`specs/collection/base_spec.md` → Per-pod metrics collection lists each case). The script's stderr, such as `kubectl`'s own error when it can't list pods, is saved beside that output as `host-collectors/run-host/router-metrics-stderr.txt`, and only when the script wrote anything to stderr. There is no top-level `router-metrics-<pod-name>/` directory in either mode.
