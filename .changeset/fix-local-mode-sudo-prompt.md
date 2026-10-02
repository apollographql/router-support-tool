---
category: fix
breaking: false
---

Stop `mode: local` collection from prompting for sudo

`collect.sh` now runs `support-bundle` with `--interactive=false`. The `router-metrics`
host collector added for per-pod metrics collection triggered the CLI's default sudo
re-exec prompt even though no host collector in this spec needs root. The prompt is
gone and collection behavior is unchanged.

Also documents the resulting bundle layout difference for `router-metrics` under
`mode: local` (`host-collectors/run-host/router-metrics/<pod-name>.txt`) versus
`mode: job` (`router-metrics-<pod-name>/result.json`) in `specs/collection/base_spec.md`
and `specs/collection/output.md`, and fixes `specs/deployment/v1/v1.md`'s `mode: local`
section which described outdated behavior.
