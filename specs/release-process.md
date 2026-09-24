# Release Process

**One release, one version, published everywhere** — One GitHub Release, tagged `vX.Y.Z`,
publishes every artifact under that same version. The release version is the single number
that identifies "what a customer gets" across the image, the chart, and the collect script. See
`specs/artifact-distribution.md` for what each artifact is and where it's published.

**Cutting a release means choosing the troubleshoot.sh version it pins.** The pinned
`support-bundle` version the image and the script bundle is a deliberate choice made as part of
cutting that release.

**Release notes come from per-PR changesets, not a hand-maintained changelog file.** Following
`apollographql/operator`'s `.changeset/` convention: a PR that changes customer-visible behavior
adds a `.changeset/<name>.md` file (`category: feat|fix|docs|ci|test` plus `breaking: true|false`
frontmatter, enforced by CI — see `.changeset/README.md`). Unlike operator's changesets, ours carry
no per-package bump-type field, since the release version here is chosen manually (below), not
computed from changesets. At release-cut time, `scripts/prepare_release_notes.sh` consumes every
pending `.changeset/*.md` file into `.changeset/notes/vX.Y.Z.md` (breaking changes first,
regardless of category, then `feat`/`fix`; `docs`/`ci`/`test` are consumed but excluded) and
deletes the consumed files. The release workflow then reads that generated file from the tagged
commit and overwrites the GitHub Release's notes with it, unconditionally, every time.

## How to cut a release

1. **Verify CI is green on `main`** for the commit being released.
2. **Confirm the troubleshoot.sh pin.** The Renovate-driven lock-step PR (Dockerfile ARG,
   `router-diagnostics-collect/collect.sh`'s own pin, chart's `troubleshoot_version`) should
   already be merged and tested.
3. **Choose the release version** (`vX.Y.Z`) — ordinary semver judgment about what changed.
4. **Open an ordinary PR bumping every checked-in version to `vX.Y.Z`**: `router-diagnostics-chart/Chart.yaml`'s
   `version:` field and `router-diagnostics-chart/values.yaml`'s `job.image.repository`/`tag`
   defaults, then `mise run generate-helm-docs`. In the same PR, run
   `scripts/prepare_release_notes.sh vX.Y.Z` — it consumes every pending `.changeset/*.md` file
   into `.changeset/notes/vX.Y.Z.md` and deletes them — and commit the result.
5. **Tag that merged commit `vX.Y.Z` and publish a GitHub Release** (or run `release.yaml` via
   `workflow_dispatch` with that version). This is what fires `release_dockerhub`,
   `release_helm_chart`, the job that overwrites the Release's notes from
   `.changeset/notes/vX.Y.Z.md`, and the job that attaches `router-diagnostics-collect/collect.sh`
   to the release as a downloadable asset.
6. **Verify the actual published artifacts** — `docker pull` the image,
   `helm show chart oci://registry-1.docker.io/apollograph/router-diagnostics-chart
   --version vX.Y.Z`, and download the script through the customer-facing Orbiter URL.
   Confirm each reports the version expected.
7. **Update customer-facing docs** if anything customer-visible changed, and ensure public docs
   are updated.
