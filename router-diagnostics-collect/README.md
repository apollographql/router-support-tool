# router-diagnostics collect script

A standalone script for `mode: local` collection. Customers download and run it directly.

The script takes `--namespace` directly rather than reading it
back from the chart release so it only needs `kubectl` and `curl` on `PATH` and has no Helm dependency.

## What it does

1. **Caches a pinned `support-bundle` binary locally** (`~/.router-diagnostics/bin` by
   default, override with `ROUTER_DIAGNOSTICS_CACHE_DIR`), keyed by version so a pin bump
   downloads a fresh binary rather than reusing a stale one.
2. **Runs `support-bundle --load-cluster-specs --auto-update=false`**, scoped to
   `--namespace` so a second `router-diagnostics` release elsewhere can't get its spec
   picked up instead.

No pod found, or a pod's port-forward never becomes ready? Collection still runs and
`router-metrics` fails with an attributable connection error rather than the run failing
outright, and `nodeMetrics` remains available as a fallback.

## Usage

```bash
./collect.sh --namespace production
```
