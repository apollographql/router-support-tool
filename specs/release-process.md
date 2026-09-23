# Release Process

**One release, one version, published everywhere** — One GitHub Release, tagged `vX.Y.Z`,
publishes every artifact under that same version. The release version is the single number
that identifies "what a customer gets" across the image, the chart, and the plugin. See
`specs/artifact-distribution.md` for what each artifact is and where it's published.

**Cutting a release means choosing the troubleshoot.sh version it pins.** The pinned
`support-bundle` version the image and plugin bundle is a deliberate choice made as part of
cutting that release.

## How to cut a release

1. **Verify CI is green on `main`** for the commit being released.
2. **Confirm the troubleshoot.sh pin** The Renovate-driven lock-step PR (Dockerfile ARG,
   plugin's `install-binary.sh`, chart's `troubleshoot_version`) should already be merged
   and tested.
3. **Choose the release version** (`vX.Y.Z`) — ordinary semver judgment about what changed.
4. **Open an ordinary PR bumping every checked-in version to `vX.Y.Z`**: `router-diagnostics-chart/Chart.yaml`'s
   `version:` field and `router-diagnostics-chart/values.yaml`'s `job.image.repository`/`tag`
   defaults, then `mise run generate-helm-docs`.
5. **Tag that merged commit `vX.Y.Z` and publish a GitHub Release** (or run `release.yaml` via
   `workflow_dispatch` with that version). This is what fires `release_dockerhub`,
   `release_helm_chart`, and `release_plugin` workflows.
6. **Verify the actual published artifacts** — `docker pull` the image,
   `helm show chart oci://registry-1.docker.io/apollograph/router-diagnostics-chart
   --version vX.Y.Z`, and install the plugin from its public URL. Confirm each
   reports the version expected.
7. **Update customer-facing docs** if anything customer-visible changed ensure public docs are
   updated.
