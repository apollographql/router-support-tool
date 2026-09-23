# Artifact Distribution

This repository produces three publishable artifacts: the `router-diagnostics-chart` Helm chart, the
`router-diagnostics-job-image` container image, and the `router-diagnostics-helm-plugin` Helm
plugin. This spec covers how each one is built and published. For versioning and how to actually
cut a release, see `specs/release-process.md`.

---

## Shared pattern: internal build, then a separate, deliberate external publish

1. **Internal build** — only the Job image has one here. `operator` also publishes its chart
   internally on every push (to `apollo-private-helm`, for verification); ours doesn't, because
   `helm-lint`/`spec-lint` already render every tier/mode combination and validate the rendered
   spec against the real pinned troubleshoot.sh binary on every PR — verification an internal
   package-and-push step wouldn't add to. The plugin has nothing to build ahead of time either
   way; it's shell, not compiled.
2. **External publish** — happens once, together, as part of cutting a release (see
   `specs/release-process.md`). Only this step produces something a customer's machine or
   cluster can actually reach.

---

## The Job image

**Source:** `router-diagnostics-job-image/` (Dockerfile bundling `support-bundle`, `aws-cli`,
`gcloud`, `curl`).

**Internal build:** `.github/workflows/build-job-image.yaml`, on every PR and every push to
`main`, unconditionally via`apollographql/release-tooling`'s shared `build_and_publish.yml`. Lands at
`us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-docker/router-diagnostics`,
tagged `edge` on `main` and `PR-<number>-<sha>` on pull requests, and by commit SHA.

**External publish:** to `docker.io/apollograph/router-diagnostics`, via
`apollographql/release-tooling/release-dockerhub`, which re-publishes the already-built internal
image by digest. Tagged with the release version (see `specs/release-process.md`).

---

## The Helm plugin

**Source:** `router-diagnostics-helm-plugin/` (`plugin.yaml`, `scripts/install-binary.sh`,
`scripts/collect.sh`).

**Internal build:** none — there's nothing to verify ahead of publish beyond what CI already
tests via the static checks and plugin integration tests.

**External publish:** to a public GCS bucket, as a tarball. Packaged fresh from the release
tag's source at publish time, authenticated the same WIF way as the Job image's publish step. 
Published as both a versioned object (`router-diagnostics-helm-plugin-v1.0.0.tar.gz`) and a
floating `router-diagnostics-helm-plugin-latest.tar.gz` that customers install against.

---

## The Helm chart

**Source:** `router-diagnostics-chart/`

**Internal build:** none — nothing to verify ahead of publish beyond what `helm-lint`/`spec-lint`
already check on every PR.

**External publish:** to `oci://registry-1.docker.io/apollograph/router-diagnostics-chart`, via
`apollographql/release-tooling/release-helm-dockerhub`. Packaged fresh from the release tag's
source.
