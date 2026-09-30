---
category: fix
breaking: false
---

Collect metrics from all router pods under `mode: local`

The single `http` collector targeting `localhost:metricsPort` is replaced with a
`hostCollectors.run` collector whose embedded shell script loops over every pod matching the
selector, sequentially port-forwards each pod's metrics port to localhost, scrapes `/metrics`,
and writes each pod's scrape to its own `<pod-name>.txt` file under `router-metrics/` in the
bundle via `outputDir`, mirroring the per-pod isolation of job mode's `http` collectors.

`collect.sh` no longer sets up a port-forward before invoking `support-bundle` — all port-forward
logic is now embedded in the run collector's shell script.
