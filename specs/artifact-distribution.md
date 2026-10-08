# Artifact Distribution

This repository produces three publishable artifacts: the `router-diagnostics-chart` Helm chart, the
`router-diagnostics-job-image` container image, and the `router-diagnostics-collect` script.
This spec covers how each one is built and published. For versioning and how to actually
cut a release, see `specs/release-process.md`.

## The Job image

**Source:** `router-diagnostics-job-image/` (Dockerfile bundling `support-bundle`, `aws-cli`,
`gcloud`, `curl`).

**Internal build:** the `build_job_image` job in `.github/workflows/run-rtf-test-plan.yaml`, on
every PR and every push to `main`, unconditionally.

**External publish:** to `docker.io/apollograph/router-diagnostics` which re-publishes the already-built internal
image by digest. Tagged with the release version (see `specs/release-process.md`).

---

## The router-diagnostics-collect scripts

**Source:** `router-diagnostics-collect/` (`collect.sh` for macOS/Linux, `collect.ps1` for Windows)

**External publish:** both scripts are attached directly to the GitHub Release as release assets.
This is the underlying artifact location, not what we point customers at directly.

**Customers install through Orbiter:**

macOS / Linux:

```bash
curl -sSLo collect.sh https://router.apollo.dev/router-diagnostics-collect/latest
```

Windows — Orbiter URL routing for `collect.ps1` is managed outside this repository. Until that
routing is in place, customers can download the script directly from the GitHub Release assets.
This is a known follow-up dependency; the script itself is shipped as a release asset from this
repository's existing release workflow.

---

## The Helm chart

**Source:** `router-diagnostics-chart/`

**Internal build:** `.github/workflows/build-chart.yaml`, on every PR and every push to `main`,
unconditionally. Publishes to Apollo's internal Helm registry, keyed by commit SHA
(`0.0.0+<sha>`) on merge to main.

**External publish:** to `oci://registry-1.docker.io/apollograph/router-diagnostics-chart`.
Packaged fresh from the release tag's source, not re-published from the internal build.
