# router-diagnostics collect script

A standalone script for `mode: local` collection. Customers download and run it directly.

## What it does

1. **Caches a pinned `support-bundle` binary locally** (`~/.router-diagnostics/bin` by
   default, override with `ROUTER_DIAGNOSTICS_CACHE_DIR`), keyed by version so a pin bump
   downloads a fresh binary rather than reusing a stale one. Replaces what used to be a
   Helm plugin install/update hook.
2. **Reads the target `router-diagnostics` release's `namespace`/`selector`/`metricsPort`
   values** (`helm get values`) - still requires `helm` on PATH and the chart already
   installed, since that's what renders the discoverable spec ConfigMap in the first
   place. Falls back to the official chart's own `app.kubernetes.io/name=router` label
   when `selector` is unset, same as `base-spec-configmap.yaml`'s collectors.
3. **Resolves the router's Service and bridges its metrics port** with a temporary
   `kubectl port-forward`, torn down on exit (success, failure, or interrupt).
4. **Runs `support-bundle --load-cluster-specs --auto-update=false`**, scoped to the
   release's namespace so a second `router-diagnostics` release elsewhere can't get its
   spec picked up instead.

No Service found, or the port-forward never becomes ready? Collection still runs and
`router-metrics` fails with an attributable connection error rather than the run failing
outright, and `nodeMetrics` remains available as a fallback.

## Usage

```bash
./collect.sh --namespace production
```

Pass a release name as a positional argument if you didn't install with the default
release name `router-diagnostics`:

```bash
./collect.sh --namespace production my-release-name
```
