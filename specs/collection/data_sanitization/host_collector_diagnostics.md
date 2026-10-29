# Host-collector run diagnostics

## The problem

`router-metrics` is a `hostCollectors.run` collector, a shell script troubleshoot.sh executes wherever `support-bundle` runs: the machine running `collect.sh` under `mode: local`, the Job's pod under `mode: job` (see `specs/collection/base_spec.md` → Per-pod metrics collection). troubleshoot.sh writes a `<collectorName>-info.json` diagnostic sidecar for this collector. It records the full exec invocation, **including the entire process environment `support-bundle` was launched with**. Under `mode: local` that is the invoking user's shell environment. Under `mode: job` it is the Job container's environment, which includes the object-storage credentials the chart injects there (`specs/storage/object_storage.md` → Credentials).

## Mitigation 1: shrink what's captured in the first place

`hostCollectors.run` supports `ignoreParentEnvs: true` (`pkg/apis/troubleshoot/v1beta2/hostcollector_shared.go`) which clears the command's environment down to just `PATH`, `KUBECONFIG`, and `PWD` instead of the full environment `support-bundle` was launched with. This narrows the sidecar's contents but doesn't eliminate them (`PWD` alone can reveal local filesystem structure or a username). Redaction below still applies regardless. `router-metrics` sets it in both modes. Under `mode: job` it is what keeps the storage credentials out of the script's environment, and it is why the script points `kubectl` at the API server explicitly instead of relying on inherited in-cluster variables (`specs/collection/base_spec.md` → Per-pod metrics collection).

## Redactor: the whole diagnostic file

The file is a single physical line of JSON (`{"command": "...", "exitCode": "0", "error": "", "outputDir": "", "input": "", "env": [...]}`). Its diagnostic value is so the file is masked wholesale, every time it appears:

```yaml
- name: router-host-collector-run-diagnostics
  fileSelector:
    files:
      - "host-collectors/run-host/*-info.json"
      - "router-metrics/*-info.json"
      - "router-resource-usage/*-info.json"
  removals:
    regex:
      - redactor: '(?P<mask>.+)'
```

### Notes

- **A single `mask` group spanning the whole line, no prefix/suffix groups** — since the file is one physical line and the entire thing is being replaced, there's nothing to preserve. The result is a file containing only `***HIDDEN***`.
- **Three `fileSelector` paths** because `specs/collection/output.md` documents that `hostCollectors.run`'s bundle layout is troubleshoot.sh-version-dependent. The newer layout nests each collector under `host-collectors/run-host/<collectorName>/`, and the first path matches every collector there. The older layout writes `<collectorName>/` at the top level, so each collector (`router-metrics/`, `router-resource-usage/`) needs its own path.
- **Scoped specifically to this collector's diagnostic sidecar, not host-collector output generally**: `host-collectors/run-host/router-metrics/pods/*.txt` (the actual scraped metrics) is left untouched and only the `*-info.json` exec-metadata file is targeted.

### Applies to every `hostCollectors.run` collector

`router-resource-usage` (`mode: job`, `specs/collection/base_spec.md` → Kubelet stats collection) is a second `hostCollectors.run` collector, so it has the same diagnostic sidecar, sets `ignoreParentEnvs: true` for the same reason, and is covered by the same redactor: `host-collectors/run-host/*-info.json` already matches it, and its alternate-layout path (`router-resource-usage/*-info.json`) is listed above. Its scraped output (`host-collectors/run-host/router-resource-usage/nodes/*/`) is, like the `router-metrics` files, left untouched.
