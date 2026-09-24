# router-diagnostics collect script

A standalone script for `mode: local` collection. Customers download and run it directly.
Has no dependency on Helm at all — it takes the same values you passed to `helm install`
directly, rather than reading them back from the chart release, so it only needs `kubectl`
and `curl` on `PATH`.

## What it does

1. **Caches a pinned `support-bundle` binary locally** (`~/.router-diagnostics/bin` by
   default, override with `ROUTER_DIAGNOSTICS_CACHE_DIR`), keyed by version so a pin bump
   downloads a fresh binary rather than reusing a stale one.
2. **Resolves the router's Service and bridges its metrics port** with a temporary
   `kubectl port-forward`, torn down on exit (success, failure, or interrupt). Uses
   `--selector` (defaulting to the official chart's own `app.kubernetes.io/name=router`
   label) and `--metrics-port` (defaulting to `9090`) — pass the same values you gave
   `helm install --set selector=...`/`--set metricsPort=...` if you overrode them there.
3. **Runs `support-bundle --load-cluster-specs --auto-update=false`**, scoped to
   `--namespace` so a second `router-diagnostics` release elsewhere can't get its spec
   picked up instead.

No Service found, or the port-forward never becomes ready? Collection still runs and
`router-metrics` fails with an attributable connection error rather than the run failing
outright, and `nodeMetrics` remains available as a fallback.

## Usage

```bash
./collect.sh --namespace production
```

If you installed the chart with a non-default `selector`/`metricsPort`, pass the same
values here:

```bash
./collect.sh --namespace production --selector "app=my-router" --metrics-port 9091
```
