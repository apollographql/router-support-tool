# Host-collector run diagnostics

## The problem

Under `mode: local`, `router-metrics` is a `hostCollectors.run` collector, a shell script troubleshoot.sh executes on the machine running `collect.sh` (see `specs/collection/base_spec.md` → Per-pod metrics collection). troubleshoot.sh writes a `<collectorName>-info.json` diagnostic sidecar for this collector. It records the full exec invocation, **including the entire process environment of the machine `collect.sh` ran on**.

## Mitigation 1: shrink what's captured in the first place

`hostCollectors.run` supports `ignoreParentEnvs: true` (`pkg/apis/troubleshoot/v1beta2/hostcollector_shared.go`) which clears the command's environment down to just `PATH`, `KUBECONFIG`, and `PWD` instead of the full environment of whoever ran `collect.sh`. This narrows the sidecar's contents but doesn't eliminate them (`PWD` alone can reveal local filesystem structure or a username). Redaction below still applies regardless.

## Redactor: the whole diagnostic file

The file is a single physical line of JSON (`{"command": "...", "exitCode": "0", "error": "", "outputDir": "", "input": "", "env": [...]}`). Its diagnostic value is so the file is masked wholesale, every time it appears:

```yaml
- name: router-host-collector-run-diagnostics
  fileSelector:
    files:
      - "host-collectors/run-host/*-info.json"
      - "router-metrics/*-info.json"
  removals:
    regex:
      - redactor: '(?P<mask>.+)'
```

### Notes

- **A single `mask` group spanning the whole line, no prefix/suffix groups** — since the file is one physical line and the entire thing is being replaced, there's nothing to preserve. The result is a file containing only `***HIDDEN***`.
- **Two `fileSelector` paths** `specs/collection/output.md` documents that `hostCollectors.run`'s bundle layout is troubleshoot.sh-version-dependent (`router-metrics/` vs. `host-collectors/run-host/<collectorName>/`).
- **Scoped specifically to this collector's diagnostic sidecar, not host-collector output generally**: `host-collectors/run-host/router-metrics/pods/*.txt` (the actual scraped metrics) is left untouched and only the `*-info.json` exec-metadata file is targeted.
