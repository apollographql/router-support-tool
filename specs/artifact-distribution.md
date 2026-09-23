# Artifact Distribution

This repository produces three publishable artifacts: the `router-diagnostics-chart` Helm chart, the
`router-diagnostics-job-image` container image, and the `router-diagnostics-helm-plugin` Helm
plugin. This spec covers how each one is built and published. For versioning and how to actually
cut a release, see `specs/release-process.md`.

## The Job image

**Source:** `router-diagnostics-job-image/` (Dockerfile bundling `support-bundle`, `aws-cli`,
`gcloud`, `curl`).

**Internal build:** `.github/workflows/build-job-image.yaml`, on every PR and every push to
`main`, unconditionally.

**External publish:** to `docker.io/apollograph/router-diagnostics` which re-publishes the already-built internal
image by digest. Tagged with the release version (see `specs/release-process.md`).

---

## The Helm plugin

**Source:** `router-diagnostics-helm-plugin/` (`plugin.yaml`, `scripts/install-binary.sh`,
`scripts/collect.sh`).

**External publish:** to a public GCS bucket, as a tarball. Packaged fresh from the release
tag's source at publish time, authenticated the same WIF way as the Job image's publish step. 
Published as both a versioned object (`router-diagnostics-helm-plugin-v1.0.0.tar.gz`) and a
floating `router-diagnostics-helm-plugin-latest.tar.gz` that customers install against.

---

## The Helm chart

**Source:** `router-diagnostics-chart/`

**External publish:** to `oci://registry-1.docker.io/apollograph/router-diagnostics-chart`.
Packaged fresh from the release tag'source.
