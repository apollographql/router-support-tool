# router-diagnostics collect scripts

Standalone scripts for `mode: local` collection. Customers download and run them directly.

The scripts take `--namespace` directly rather than reading it back from the chart release,
so they only need `kubectl` on `PATH` (plus `curl` on Unix) and have no Helm dependency.

## What they do

1. **Cache a pinned `support-bundle` binary locally** (`~/.router-diagnostics/bin` by
   default, override with `ROUTER_DIAGNOSTICS_CACHE_DIR`), keyed by version so a pin bump
   downloads a fresh binary rather than reusing a stale one.
2. **Run `support-bundle --load-cluster-specs --auto-update=false`**, scoped to
   `--namespace` so a second `router-diagnostics` release elsewhere can't get its spec
   picked up instead.

## Usage

**macOS / Linux** (`collect.sh`, requires `kubectl` and `curl`):

```bash
./collect.sh --namespace production
```

**Windows** (`collect.ps1`, requires `kubectl`):

```powershell
.\collect.ps1 -Namespace production
```
