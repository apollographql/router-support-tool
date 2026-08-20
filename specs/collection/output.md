# Bundle Output Shape

What a produced bundle actually looks like once you extract it — the directory layout, which files are real content versus symlinks, and where each signal documented in `specs/collection/base_spec.md` actually lands. Verified against troubleshoot.sh source and docs at `v0.120.0`, the same pin used throughout `specs/collection/`.

## The archive itself

`kubectl support-bundle` produces a single `support-bundle-<timestamp>.tar.gz`. Extracting it yields one top-level directory, named from the same timestamped basename as the archive — [`supportbundle.go#L91`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/supportbundle/supportbundle.go#L91):

```
support-bundle-2026-08-11T14_23_00/
```

Everything below is relative to that one directory. See `specs/collection/meta_json.md` → Collection time for why this directory name is the closest thing to a collection timestamp this tool has.

## Root-level files

Three files always land at the root, regardless of what the spec collects:

| File | Written by | Notes |
| --- | --- | --- |
| `version.yaml` | The engine itself, unconditionally | The troubleshoot.sh version that produced the bundle. See `specs/collection/meta_json.md` → Do not duplicate the engine version. |
| `analysis.json` | The engine, unconditionally | [`supportbundle.go#L168-187`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/supportbundle/supportbundle.go#L168) runs analysis and writes this file on every collection, whether or not the spec declares any analyzers. **The base spec declares none** (`specs/collection/base_spec.md` → "the base spec ships no analyzers"), so expect this file to be present but empty/trivial in every bundle this tool produces — its presence is not a sign an analyzer ran. |
| `meta.json` | Us, via the `data` collector | Not an engine file — see `specs/collection/meta_json.md` for what it holds and why. |

A fourth file, `metadata/user.json`, appears only if the customer passes `--metadata` at invocation (per [troubleshoot.sh's own documentation](https://troubleshoot.sh/docs/support-bundle/collecting/)). This tool's documented invocations (`specs/user_experience.md`) don't use that flag, so don't expect it in a bundle produced by the documented flows.

## Collector output: three different shapes, not two

`specs/collection/collector_naming.md` documents three cases: name-controlled, engine-fixed, and the hybrid (`logs`) where the chosen name only controls a symlink while the real storage is engine-fixed. This section is the worked-out directory shape for all three; see that file for the naming rules and rationale.

### 1. Fully name-controlled — `http` (`router-metrics`)

Confirmed from [`http.go`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/http.go): `SaveResult` writes directly to `filepath.Join(c.Collector.Name, fileName)`. No indirection.

```
router-metrics/
└── result.json
```

### 2. Name-controlled via symlink, not real storage — `logs` (`router-runtime-logs`)

Confirmed from [`logs.go` `savePodLogs`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/collect/logs.go#L138): the actual log content is written under the **engine-fixed** `cluster-resources/pods/logs/` tree, not under the collector's own name. The `router-runtime-logs/` path that appears to hold the logs is a **symlink** to that real location — created because this collector's call site passes `createSymLinks: true`.

```
cluster-resources/
└── pods/
    └── logs/
        └── <namespace>/
            └── <pod-name>/
                ├── <container-name>.log              # the real file
                └── <container-name>-previous.log     # always collected, see base_spec.md → main table

router-runtime-logs/
└── <pod-name>/
    └── <container-name>.log -> ../../cluster-resources/pods/logs/<namespace>/<pod-name>/<container-name>.log
```

**Why this matters:** if a customer's tooling doesn't preserve symlinks on extraction (some Windows extraction tools, some archive-scanning pipelines), `router-runtime-logs/` can come up empty or broken while the actual log content is intact under `cluster-resources/pods/logs/`. Anyone troubleshooting a bundle that looks like it's missing logs should check the `cluster-resources/pods/logs/` path directly before concluding logs weren't collected.

### 3. Fully engine-fixed — `clusterResources`, `nodeMetrics`, `helm`, `configMap`

The `name:` field is a display label only; every path below is hardcoded by the engine regardless of what name the spec gives these collectors. Per `specs/collection/collector_naming.md` → Engine-fixed collectors, verified against source:

```
cluster-resources/
├── pods/<namespace>.json                    # pod status, restarts, limits, env vars, router version
├── configmaps/<namespace>.json              # full ConfigMap sweep of the namespace — includes router.yaml's
│                                             #   ConfigMap AND the spec's own ConfigMap (mode: local/job)
├── events/<namespace>.json                  # OOM kill occurrences, per CLUSTER_RESOURCES_EVENTS
├── nodes.json                                # node objects — MemoryPressure/DiskPressure conditions
│                                             #   (not namespaced, one file for the whole cluster)
├── namespaces.json
├── services/<namespace>.json
├── deployments/<namespace>.json
├── statefulsets/<namespace>.json
├── daemonsets/<namespace>.json
├── pod-disruption-budgets/<namespace>.json
├── auth-cani-list/<namespace>.json          # one file per namespace, not a single combined file —
│                                             #   confirmed from authCanI()'s map keys in cluster_resources.go
└── (plus other resource types the engine always dumps — replicasets, jobs, cronjobs, ingress,
     network policy, RBAC objects, etc. — collected because clusterResources is not
     type-selective, not because the base spec asks for them)

node-metrics/
└── <node-name>.json                          # memory.*, cpu.*, cpu.psi/memory.psi if populated —
                                                #   see base_spec.md → Memory and CPU information collected

helm/
└── <namespace>.json                          # or <namespace>/<releaseName>.json if releaseName is set —
                                                #   the Helm values layer

configmaps/
└── <namespace>/
    └── <configmap-name>.json                 # the configMap collector's own output — NOT nested
                                                #   under cluster-resources/, and NOT the same file as
                                                #   cluster-resources/configmaps/<namespace>.json above
```

**The two `configmaps` paths are easy to confuse and mean different things.** `cluster-resources/configmaps/<namespace>.json` is `clusterResources`'s full, unfiltered sweep of every ConfigMap in the namespace (this is what carries the credential-exposure risk discussed in `specs/collection/base_spec.md` → Redis health, and what schema/SDL rides along in per `specs/collection/base_spec.md` → Where graph schema/SDL actually lands). The top-level `configmaps/<namespace>/<name>.json` is the standalone `configMap` collector's own output — one file per label match, named after the real ConfigMap (`specs/collection/base_spec.md` → `router.yaml` capture; this is also what makes the multiple-router-releases signal observable, per `specs/collection/meta_json.md` → Multiple router releases in one namespace).

## A worked example

For a `mode: job` install in `production`, tying this together with `specs/collection/meta_json.md`'s complete example:

```
support-bundle-2026-08-11T14_23_00/
├── version.yaml
├── analysis.json
├── meta.json
├── router-metrics/
│   └── result.json
├── router-runtime-logs/
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

If more than one router release matched the label selector in `production`, the last entry becomes multiple files — one per release — per `specs/collection/meta_json.md` → Multiple router releases in one namespace.

