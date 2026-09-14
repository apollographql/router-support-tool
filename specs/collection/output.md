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
├── router-metrics/
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
├── helm/
│   └── production.json
└── configmaps/
    └── production/
        └── <release-name>.json
```

Notes: 
- If more than one router release matched the label selector in `production`, the last entry becomes multiple files — one per release.

- `cluster-resources/configmaps/production.json` is `clusterResources`'s full, unfiltered sweep of every ConfigMap in the namespace (schema is found here). `configmaps/production/<release-name>.json` is the dedicated `configMap` collector's own output, one file per matched release.

