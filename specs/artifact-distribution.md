# Artifact Distribution

This repository produces three publishable artifacts: the `router-diagnostics-chart` Helm chart, the
`router-diagnostics-job-image` container image, and the `router-diagnostics-collect` script.
This spec covers how each one is built and published. For versioning and how to actually
cut a release, see `specs/release-process.md`.

## The Job image

**Source:** `router-diagnostics-job-image/` (Dockerfile bundling `support-bundle`, `aws-cli`,
`gcloud`, `curl`).

**Internal build:** `.github/workflows/build-job-image.yaml`, on every PR and every push to
`main`, unconditionally.

**External publish:** to `docker.io/apollograph/router-diagnostics` which re-publishes the already-built internal
image by digest. Tagged with the release version (see `specs/release-process.md`).

---

## The router-diagnostics-collect script

**Source:** `router-diagnostics-collect/` (`collect.sh`)

**External publish:** attached directly to the GitHub Release as a release asset. This is the
underlying artifact location, not what we point customers at directly.

**Customers install through Orbiter:**

```bash
curl -sSLo collect.sh https://rover.apollo.dev/<path-TODO>/router-diagnostics-collect/latest
```

---

## The Helm chart

**Source:** `router-diagnostics-chart/`

**Internal build:** `.github/workflows/build-chart.yaml`, on every PR and every push to `main`,
unconditionally. Publishes to Apollo's internal registry
(`oci://us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-helm`), keyed by
commit SHA (`0.0.0+<sha>`) on merge to main.

**External publish:** to `oci://registry-1.docker.io/apollograph/router-diagnostics-chart`.
Packaged fresh from the release tag's source, not re-published from the internal build.
