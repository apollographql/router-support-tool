# router-diagnostics Job image

The container image `router-diagnostics`'s `mode: job` runs bundling the `support-bundle`
binary plus `aws-cli`/`gcloud`/`curl` for the object-storage upload paths.

## Where it's published

Two registries, two audiences:

- **Internal build** — every PR and every push to `main` builds and pushes this image to
  Apollo's private registry, `us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-docker/router-diagnostics`,
  tagged `edge` on `main` and `PR-<number>-<sha>` on pull requests (`.github/workflows/build-job-image.yml`,
  via `apollographql/release-tooling`'s shared `build_and_publish.yml`). This is what
  `testing/data/scenario.sh`'s RTF verification plan runs against (`:edge`) — it never needs
  the public image to exist.
- **Public release** — on a GitHub Release, `.github/workflows/release-job-image.yml`
  republishes that same already-built image (by digest, not a rebuild) to the public
  `docker.io/apollograph/router-diagnostics`, tagged with the release version plus `:latest`.
  This is what `router-diagnostics`'s chart defaults (`job.image.repository`/`job.image.tag`)
  point customers at — the same internal-build-then-external-publish pattern
  `apollographql/operator` uses for its own image and Helm chart.

## Version pinning

The bundled `support-bundle` version (currently `0.134.1`) is pinned by the `SUPPORT_BUNDLE_VERSION`
build arg below, tracked by the same Renovate custom manager (`.github/renovate.json5`) that
keeps the Helm plugin's pin and the chart's declared `troubleshoot_version` in lock-step — a
version bump here always arrives in the same PR as those two. Per CLAUDE.md, treat any such
bump as a deliberate, reviewed change: verify it against a real run before merging, not just
against `support-bundle lint` (which `spec_lint` in `.github/workflows/static-checks.yaml`
already does).

The image's own version (its Docker Hub tag) is independent of that pin — this image doesn't
yet have enough moving parts to warrant separate semver, so its public tag mirrors the
`support-bundle` version it bundles (e.g. `v0.134.1`) rather than tracking its own release
number.

## Local build and test

```bash
docker build --platform linux/arm64 -t router-diagnostics-job-image:dev router-diagnostics-job-image
```

Use `linux/amd64` instead if your `kind` nodes are x86.

```bash
kind load docker-image router-diagnostics-job-image:dev --name <your-cluster>

helm upgrade --install router-diagnostics router-diagnostics \
  --namespace <namespace> \
  --set namespace=<namespace> \
  --set mode=job \
  --set job.image.repository=router-diagnostics-job-image \
  --set job.image.tag=dev \
  --set job.image.pullPolicy=IfNotPresent
```
