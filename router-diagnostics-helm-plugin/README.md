# router-diagnostics Helm plugin

Implements the `helm router-diagnostics collect` command.

**Not yet installable the way the spec documents.** `helm plugin install <url>`
clones the whole repo at that URL and requires `plugin.yaml` at its root. This plugin currently lives here for development, so `helm plugin install
https://github.com/apollographql/router-diagnostics-helm-plugin` (the spec's
install command) won't work until this directory is extracted and published —
will be completed in [RR-1145](https://apollographql.atlassian.net/browse/RR-1145). Test locally with:

```bash
helm plugin install ./router-diagnostics-helm-plugin
```

## What it does

1. **Install/update hook** (`scripts/install-binary.sh`): downloads a pinned
   `support-bundle` release into the plugin's own directory.

2. **`scripts/collect.sh`**: reads the target `router-diagnostics` release's
   `namespace` and `selector` values, resolves the router's Service by that
   label (falling back to the official chart's own `app.kubernetes.io/name=router`
   when `selector` is unset, same as `base-spec-configmap.yaml`'s collectors),
   bridges its metrics port with a temporary `kubectl port-forward` (torn down
   on exit, success or failure), then runs `support-bundle --load-cluster-specs
   --namespace <release namespace> --auto-update=false` - scoped, so a second
   router-diagnostics release in another namespace can't get its spec picked up
   instead, and pinned, so support-bundle's default self-update behavior can't
   silently swap out the version the plugin just installed.

No Service found, or the port-forward never becomes ready? Collection still
runs and `router-metrics` fails with an attributable connection error rather
than the run failing outright, and `nodeMetrics` remains available as a
fallback.
